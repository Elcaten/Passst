import Foundation

struct ClipboardSourceFilter: Hashable, Identifiable, Sendable {
    let bundleIdentifier: String?
    let applicationName: String

    var id: String {
        bundleIdentifier ?? "name:\(applicationName)"
    }
}

enum ClipboardDateFilter: String, CaseIterable, Identifiable, Sendable {
    case today
    case yesterday
    case lastWeek
    case lastMonth

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .lastWeek: "Last Week"
        case .lastMonth: "Last Month"
        }
    }

    var symbolName: String {
        switch self {
        case .today: "calendar"
        case .yesterday: "calendar.badge.minus"
        case .lastWeek, .lastMonth: "calendar.badge.clock"
        }
    }

    var interval: DateInterval {
        let calendar = Calendar.autoupdatingCurrent
        let now = Date()
        let today = calendar.startOfDay(for: now)
        switch self {
        case .today:
            return DateInterval(
                start: today,
                end: calendar.date(byAdding: .day, value: 1, to: today) ?? now
            )
        case .yesterday:
            return DateInterval(
                start: calendar.date(byAdding: .day, value: -1, to: today) ?? today,
                end: today
            )
        case .lastWeek:
            return DateInterval(
                start: calendar.date(byAdding: .day, value: -7, to: now) ?? today,
                end: now.addingTimeInterval(1)
            )
        case .lastMonth:
            return DateInterval(
                start: calendar.date(byAdding: .month, value: -1, to: now) ?? today,
                end: now.addingTimeInterval(1)
            )
        }
    }
}

struct ClipboardSearchFilters: Equatable, Sendable {
    var kinds: Set<ClipboardContentKind> = []
    var source: ClipboardSourceFilter?
    var date: ClipboardDateFilter?

    var isEmpty: Bool {
        kinds.isEmpty && source == nil && date == nil
    }

    @discardableResult
    mutating func removeTrailingFilter() -> Bool {
        if date != nil {
            date = nil
        } else if source != nil {
            source = nil
        } else if !kinds.isEmpty {
            kinds.removeAll()
        } else {
            return false
        }
        return true
    }
}
