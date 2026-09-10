@preconcurrency import GRDB
import Foundation
import OSLog
import UniformTypeIdentifiers

actor HistoryRepository {
    private static let logger = Logger(
        subsystem: "app.passst.mac",
        category: "HistoryRepository"
    )

    enum RepositoryError: LocalizedError {
        case invalidRecord
        case saveAndCleanupFailed(save: String, cleanup: String)

        var errorDescription: String? {
            switch self {
            case .invalidRecord:
                "Passst found an invalid history record."
            case let .saveAndCleanupFailed(save, cleanup):
                "History save failed (\(save)); temporary file cleanup also failed (\(cleanup))."
            }
        }
    }

    private let database: DatabaseQueue
    let payloadStore: PayloadStore

    init(rootURL: URL? = nil) throws {
        let store = try PayloadStore(rootURL: rootURL)
        self.payloadStore = store

        let root = try Self.resolveRootURL(rootURL)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try DatabaseQueue(path: root.appendingPathComponent("history.sqlite").path)
        try Self.migrate(database)
    }

    private static func resolveRootURL(_ supplied: URL?) throws -> URL {
        if let supplied { return supplied }
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw PayloadStore.StoreError.applicationSupportUnavailable
        }
        return applicationSupport.appendingPathComponent("Passst", isDirectory: true)
    }

    private static func migrate(_ database: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createHistory") { db in
            try db.execute(sql: """
                CREATE TABLE clipboard_records (
                    id TEXT PRIMARY KEY NOT NULL,
                    kind TEXT NOT NULL,
                    createdAt REAL NOT NULL,
                    updatedAt REAL NOT NULL,
                    displayTitle TEXT NOT NULL,
                    previewText TEXT NOT NULL,
                    searchableText TEXT NOT NULL,
                    sourceBundleIdentifier TEXT,
                    sourceApplicationName TEXT,
                    payloadFilename TEXT NOT NULL,
                    thumbnailFilename TEXT,
                    payloadDigest TEXT NOT NULL UNIQUE,
                    byteCount INTEGER NOT NULL
                );
                CREATE INDEX clipboard_records_updatedAt
                    ON clipboard_records(updatedAt DESC);
                CREATE INDEX clipboard_records_digest
                    ON clipboard_records(payloadDigest);
                """)
            try db.execute(sql: """
                CREATE VIRTUAL TABLE clipboard_search USING fts5(
                    id UNINDEXED,
                    displayTitle,
                    searchableText,
                    sourceApplicationName,
                    tokenize = 'unicode61 remove_diacritics 2'
                );
                """)
        }
        migrator.registerMigration("addCategories") { db in
            try db.alter(table: "clipboard_records") { table in
                table.add(column: "categoryID", .text)
            }
            try db.create(
                index: "clipboard_records_categoryID",
                on: "clipboard_records",
                columns: ["categoryID"]
            )
        }
        try migrator.migrate(database)
    }

    @discardableResult
    func save(
        payload: ClipboardPayload,
        metadata: ClipboardRecord
    ) async throws -> ClipboardRecord {
        if let existing = try await record(withDigest: metadata.payloadDigest) {
            do {
                _ = try await payloadStore.read(filename: existing.payloadFilename)
            } catch {
                Self.logger.notice(
                    "Repairing inaccessible duplicate \(existing.id.uuidString, privacy: .public)"
                )
                return try await repairDuplicate(existing, with: payload)
            }

            let now = Date()
            try await database.write { db in
                try db.execute(
                    sql: "UPDATE clipboard_records SET updatedAt = ? WHERE id = ?",
                    arguments: [now.timeIntervalSince1970, existing.id.uuidString]
                )
            }
            var moved = existing
            moved.updatedAt = now
            return moved
        }

        let payloadFilename = try await payloadStore.write(payload, id: metadata.id)
        let thumbnailFilename: String?
        do {
            thumbnailFilename = try await payloadStore.writeThumbnail(from: payload, id: metadata.id)
        } catch {
            thumbnailFilename = nil
        }

        var preparedRecord = metadata
        preparedRecord.payloadFilename = payloadFilename
        preparedRecord.thumbnailFilename = thumbnailFilename
        let record = preparedRecord

        do {
            try await database.write { db in
                try Self.insert(record, db: db)
                try Self.insertSearch(record, db: db)
            }
            return record
        } catch let saveError {
            do {
                try await payloadStore.delete(
                    payloadFilename: payloadFilename,
                    thumbnailFilename: thumbnailFilename
                )
            } catch let cleanupError {
                throw RepositoryError.saveAndCleanupFailed(
                    save: saveError.localizedDescription,
                    cleanup: cleanupError.localizedDescription
                )
            }
            throw saveError
        }
    }

    func page(
        query: String,
        categoryID: UUID? = nil,
        filters: ClipboardSearchFilters = ClipboardSearchFilters(),
        offset: Int,
        limit: Int = 100
    ) async throws -> HistoryPage {
        let boundedLimit = max(1, min(limit, 200))
        let rows: [Row]
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let categoryValue = categoryID?.uuidString
        let selectedKinds = ClipboardContentKind.allCases.map {
            filters.kinds.contains($0) ? $0.rawValue : ""
        }
        let sourceEnabled = filters.source == nil ? 0 : 1
        let sourceBundleIdentifier = filters.source?.bundleIdentifier
        let sourceApplicationName = filters.source?.applicationName
        let dateInterval = filters.date?.interval
        let dateStart = dateInterval?.start.timeIntervalSince1970
        let dateEnd = dateInterval?.end.timeIntervalSince1970

        if trimmedQuery.isEmpty {
            rows = try database.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                        SELECT r.*
                        FROM clipboard_records AS r
                        WHERE (? IS NULL OR r.categoryID = ?)
                          AND (
                            ? = 0
                            OR r.kind IN (?, ?, ?, ?, ?, ?, ?, ?)
                          )
                          AND (
                            ? = 0
                            OR (
                              (? IS NOT NULL AND r.sourceBundleIdentifier = ?)
                              OR (? IS NULL AND r.sourceApplicationName = ?)
                            )
                          )
                          AND (
                            ? IS NULL
                            OR (r.updatedAt >= ? AND r.updatedAt < ?)
                          )
                        ORDER BY r.updatedAt DESC
                        LIMIT ? OFFSET ?
                        """,
                    arguments: [
                        categoryValue, categoryValue,
                        filters.kinds.isEmpty ? 0 : 1,
                        selectedKinds[0], selectedKinds[1],
                        selectedKinds[2], selectedKinds[3],
                        selectedKinds[4], selectedKinds[5],
                        selectedKinds[6], selectedKinds[7],
                        sourceEnabled,
                        sourceBundleIdentifier, sourceBundleIdentifier,
                        sourceBundleIdentifier, sourceApplicationName,
                        dateStart, dateStart, dateEnd,
                        boundedLimit + 1, max(0, offset)
                    ]
                )
            }
        } else {
            let normalized = Self.searchExpression(query)
            let like = "%\(query)%"
            rows = try database.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                        SELECT r.*
                        FROM clipboard_records AS r
                        WHERE (? IS NULL OR r.categoryID = ?)
                          AND (
                            ? = 0
                            OR r.kind IN (?, ?, ?, ?, ?, ?, ?, ?)
                          )
                          AND (
                            ? = 0
                            OR (
                              (? IS NOT NULL AND r.sourceBundleIdentifier = ?)
                              OR (? IS NULL AND r.sourceApplicationName = ?)
                            )
                          )
                          AND (
                            ? IS NULL
                            OR (r.updatedAt >= ? AND r.updatedAt < ?)
                          )
                          AND (
                            r.id IN (
                                SELECT id FROM clipboard_search
                                WHERE clipboard_search MATCH ?
                            )
                            OR r.displayTitle LIKE ?
                            OR r.searchableText LIKE ?
                            OR COALESCE(r.sourceApplicationName, '') LIKE ?
                          )
                        ORDER BY r.updatedAt DESC
                        LIMIT ? OFFSET ?
                        """,
                    arguments: [
                        categoryValue, categoryValue,
                        filters.kinds.isEmpty ? 0 : 1,
                        selectedKinds[0], selectedKinds[1],
                        selectedKinds[2], selectedKinds[3],
                        selectedKinds[4], selectedKinds[5],
                        selectedKinds[6], selectedKinds[7],
                        sourceEnabled,
                        sourceBundleIdentifier, sourceBundleIdentifier,
                        sourceBundleIdentifier, sourceApplicationName,
                        dateStart, dateStart, dateEnd,
                        normalized, like, like, like,
                        boundedLimit + 1, max(0, offset)
                    ]
                )
            }
        }

        var records = try rows.prefix(boundedLimit).map(Self.decode)
        for index in records.indices {
            if [.text, .richText].contains(records[index].kind),
               CodeDetector.isLikelyCode(records[index].previewText) {
                var codeRecord = records[index]
                codeRecord.kind = .code
                do {
                    records[index] = try await persistReclassification(codeRecord)
                } catch {
                    Self.logger.error(
                        "Could not persist code type for \(records[index].id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
                continue
            }
            guard records[index].kind == .mixed else { continue }
            do {
                records[index] = try await reclassifiedRecord(records[index])
            } catch {
                do {
                    if let fallback = try await imageRecordFromStoredMetadata(records[index]) {
                        records[index] = fallback
                        Self.logger.notice(
                            "Reclassified protected image \(fallback.id.uuidString, privacy: .public) from stored metadata"
                        )
                    } else {
                        Self.logger.error(
                            "Could not reclassify record \(records[index].id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
                        )
                    }
                } catch let fallbackError {
                    Self.logger.error(
                        "Could not persist fallback type for \(records[index].id.uuidString, privacy: .public): \(fallbackError.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
        return HistoryPage(records: records, hasMore: rows.count > boundedLimit)
    }

    func payload(for record: ClipboardRecord) async throws -> ClipboardPayload {
        try await payloadStore.read(filename: record.payloadFilename)
    }

    func thumbnailURL(for record: ClipboardRecord) async -> URL? {
        await payloadStore.thumbnailURL(filename: record.thumbnailFilename)
    }

    func sourceApplications() async throws -> [ClipboardSourceFilter] {
        let rows: [Row] = try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT sourceBundleIdentifier, sourceApplicationName,
                           MAX(updatedAt) AS mostRecent
                    FROM clipboard_records
                    WHERE sourceApplicationName IS NOT NULL
                      AND sourceApplicationName != ''
                    GROUP BY COALESCE(sourceBundleIdentifier, sourceApplicationName)
                    ORDER BY mostRecent DESC
                    LIMIT 24
                    """
            )
        }
        return rows.compactMap { row in
            let applicationName: String? = row["sourceApplicationName"]
            guard let applicationName else { return nil }
            let bundleIdentifier: String? = row["sourceBundleIdentifier"]
            return ClipboardSourceFilter(
                bundleIdentifier: bundleIdentifier,
                applicationName: applicationName
            )
        }
    }

    func setCategory(_ categoryID: UUID?, for id: UUID) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE clipboard_records SET categoryID = ? WHERE id = ?",
                arguments: [categoryID?.uuidString, id.uuidString]
            )
        }
    }

    func removeCategoryReferences(_ categoryID: UUID) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE clipboard_records SET categoryID = NULL WHERE categoryID = ?",
                arguments: [categoryID.uuidString]
            )
        }
    }

    func rename(id: UUID, title: String) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE clipboard_records SET displayTitle = ? WHERE id = ?",
                arguments: [title, id.uuidString]
            )
            try db.execute(
                sql: "DELETE FROM clipboard_search WHERE id = ?",
                arguments: [id.uuidString]
            )
            try db.execute(
                sql: """
                    INSERT INTO clipboard_search (
                        id, displayTitle, searchableText, sourceApplicationName
                    )
                    SELECT id, displayTitle, searchableText,
                           COALESCE(sourceApplicationName, '')
                    FROM clipboard_records
                    WHERE id = ?
                    """,
                arguments: [id.uuidString]
            )
        }
    }

    func delete(id: UUID) async throws {
        guard let record = try await record(id: id) else { return }
        try await database.write { db in
            try db.execute(
                sql: "DELETE FROM clipboard_search WHERE id = ?",
                arguments: [id.uuidString]
            )
            try db.execute(
                sql: "DELETE FROM clipboard_records WHERE id = ?",
                arguments: [id.uuidString]
            )
        }
        try await payloadStore.delete(
            payloadFilename: record.payloadFilename,
            thumbnailFilename: record.thumbnailFilename
        )
    }

    func clear() async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM clipboard_search")
            try db.execute(sql: "DELETE FROM clipboard_records")
        }
        try await payloadStore.removeAllPayloads()
    }

    func storageSize() async throws -> Int64 {
        try await payloadStore.storageSize()
    }

    func record(id: UUID) async throws -> ClipboardRecord? {
        try await database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM clipboard_records WHERE id = ?",
                arguments: [id.uuidString]
            ) else {
                return nil
            }
            return try Self.decode(row)
        }
    }

    private func record(withDigest digest: String) async throws -> ClipboardRecord? {
        try await database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM clipboard_records WHERE payloadDigest = ?",
                arguments: [digest]
            ) else {
                return nil
            }
            return try Self.decode(row)
        }
    }

    private func reclassifiedRecord(_ record: ClipboardRecord) async throws -> ClipboardRecord {
        let payload = try await payloadStore.read(filename: record.payloadFilename)
        let metadata = ClipboardPayloadClassifier.makeRecord(
            for: payload,
            sourceBundleIdentifier: record.sourceBundleIdentifier,
            sourceApplicationName: record.sourceApplicationName
        )
        guard metadata.kind != record.kind else { return record }

        var updated = record
        updated.kind = metadata.kind
        updated.displayTitle = metadata.displayTitle
        updated.previewText = metadata.previewText
        updated.searchableText = metadata.searchableText

        if updated.kind == .image, updated.thumbnailFilename == nil {
            updated.thumbnailFilename = try await payloadStore.writeThumbnail(
                from: payload,
                id: updated.id
            )
        }

        return try await persistReclassification(updated)
    }

    private func imageRecordFromStoredMetadata(
        _ record: ClipboardRecord
    ) async throws -> ClipboardRecord? {
        guard record.thumbnailFilename != nil else { return nil }
        let candidate = record.previewText
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? record.displayTitle
        let fileExtension = URL(fileURLWithPath: candidate).pathExtension
        guard !fileExtension.isEmpty,
              UTType(filenameExtension: fileExtension)?.conforms(to: .image) == true
        else {
            return nil
        }

        var updated = record
        updated.kind = .image
        updated.displayTitle = URL(fileURLWithPath: candidate).lastPathComponent
        return try await persistReclassification(updated)
    }

    private func persistReclassification(
        _ updated: ClipboardRecord
    ) async throws -> ClipboardRecord {
        let persisted = updated
        try await database.write { db in
            try db.execute(
                sql: """
                    UPDATE clipboard_records
                    SET kind = ?, displayTitle = ?, previewText = ?,
                        searchableText = ?, thumbnailFilename = ?
                    WHERE id = ?
                    """,
                arguments: [
                    persisted.kind.rawValue,
                    persisted.displayTitle,
                    persisted.previewText,
                    persisted.searchableText,
                    persisted.thumbnailFilename,
                    persisted.id.uuidString
                ]
            )
            try db.execute(
                sql: "DELETE FROM clipboard_search WHERE id = ?",
                arguments: [persisted.id.uuidString]
            )
            try Self.insertSearch(persisted, db: db)
        }
        return persisted
    }

    private func repairDuplicate(
        _ existing: ClipboardRecord,
        with payload: ClipboardPayload
    ) async throws -> ClipboardRecord {
        let replacementID = UUID()
        let payloadFilename = try await payloadStore.write(payload, id: replacementID)
        let thumbnailFilename: String?
        do {
            thumbnailFilename = try await payloadStore.writeThumbnail(
                from: payload,
                id: replacementID
            )
        } catch {
            Self.logger.error(
                "Could not rebuild thumbnail for \(existing.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            thumbnailFilename = nil
        }

        let metadata = ClipboardPayloadClassifier.makeRecord(
            for: payload,
            sourceBundleIdentifier: existing.sourceBundleIdentifier,
            sourceApplicationName: existing.sourceApplicationName
        )
        var repaired = existing
        repaired.kind = metadata.kind
        repaired.updatedAt = Date()
        repaired.displayTitle = metadata.displayTitle
        repaired.previewText = metadata.previewText
        repaired.searchableText = metadata.searchableText
        repaired.payloadFilename = payloadFilename
        repaired.thumbnailFilename = thumbnailFilename
        repaired.byteCount = payload.byteCount
        let persisted = repaired

        do {
            try await database.write { db in
                try db.execute(
                    sql: """
                        UPDATE clipboard_records
                        SET kind = ?, updatedAt = ?, displayTitle = ?, previewText = ?,
                            searchableText = ?, payloadFilename = ?,
                            thumbnailFilename = ?, byteCount = ?
                        WHERE id = ?
                        """,
                    arguments: [
                        persisted.kind.rawValue,
                        persisted.updatedAt.timeIntervalSince1970,
                        persisted.displayTitle,
                        persisted.previewText,
                        persisted.searchableText,
                        persisted.payloadFilename,
                        persisted.thumbnailFilename,
                        persisted.byteCount,
                        persisted.id.uuidString
                    ]
                )
                try db.execute(
                    sql: "DELETE FROM clipboard_search WHERE id = ?",
                    arguments: [persisted.id.uuidString]
                )
                try Self.insertSearch(persisted, db: db)
            }
        } catch let saveError {
            do {
                try await payloadStore.delete(
                    payloadFilename: payloadFilename,
                    thumbnailFilename: thumbnailFilename
                )
            } catch let cleanupError {
                throw RepositoryError.saveAndCleanupFailed(
                    save: saveError.localizedDescription,
                    cleanup: cleanupError.localizedDescription
                )
            }
            throw saveError
        }
        return persisted
    }

    private static func insert(_ record: ClipboardRecord, db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO clipboard_records (
                    id, kind, createdAt, updatedAt, displayTitle, previewText,
                    searchableText, sourceBundleIdentifier, sourceApplicationName,
                    categoryID, payloadFilename, thumbnailFilename, payloadDigest, byteCount
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                record.id.uuidString,
                record.kind.rawValue,
                record.createdAt.timeIntervalSince1970,
                record.updatedAt.timeIntervalSince1970,
                record.displayTitle,
                record.previewText,
                record.searchableText,
                record.sourceBundleIdentifier,
                record.sourceApplicationName,
                record.categoryID?.uuidString,
                record.payloadFilename,
                record.thumbnailFilename,
                record.payloadDigest,
                record.byteCount
            ]
        )
    }

    private static func insertSearch(_ record: ClipboardRecord, db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO clipboard_search (
                    id, displayTitle, searchableText, sourceApplicationName
                ) VALUES (?, ?, ?, ?)
                """,
            arguments: [
                record.id.uuidString,
                record.displayTitle,
                record.searchableText,
                record.sourceApplicationName ?? ""
            ]
        )
    }

    private static func decode(_ row: Row) throws -> ClipboardRecord {
        guard
            let id = UUID(uuidString: row["id"]),
            let kind = ClipboardContentKind(rawValue: row["kind"])
        else {
            throw RepositoryError.invalidRecord
        }
        return ClipboardRecord(
            id: id,
            kind: kind,
            createdAt: Date(timeIntervalSince1970: row["createdAt"]),
            updatedAt: Date(timeIntervalSince1970: row["updatedAt"]),
            displayTitle: row["displayTitle"],
            previewText: row["previewText"],
            searchableText: row["searchableText"],
            sourceBundleIdentifier: row["sourceBundleIdentifier"],
            sourceApplicationName: row["sourceApplicationName"],
            categoryID: (row["categoryID"] as String?).flatMap(UUID.init(uuidString:)),
            payloadFilename: row["payloadFilename"],
            thumbnailFilename: row["thumbnailFilename"],
            payloadDigest: row["payloadDigest"],
            byteCount: row["byteCount"]
        )
    }

    static func searchExpression(_ query: String) -> String {
        query
            .split(whereSeparator: \.isWhitespace)
            .map { token in
                let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\"*"
            }
            .joined(separator: " AND ")
    }
}
