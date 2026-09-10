import AppKit
import SwiftUI
import UniformTypeIdentifiers

private struct CategoryBarElementShape: InsettableShape {
    private var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        if #available(macOS 26.0, *) {
            Capsule()
                .inset(by: insetAmount)
                .path(in: rect)
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .inset(by: insetAmount)
                .path(in: rect)
        }
    }

    func inset(by amount: CGFloat) -> CategoryBarElementShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
}

struct CategoryBar: View {
    @Bindable var model: AppModel
    let maximumWidth: CGFloat

    @Environment(\.colorScheme) private var colorScheme
    @State private var targetedCategoryID: UUID?
    @State private var hoveredCategoryID: String?
    @State private var creatingTag = false
    @State private var addTagHovered = false
    @State private var newTagName = ""
    @State private var newTagColor = ClipboardCategory.palette[4]
    @FocusState private var tagNameFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            categoryButton(
                title: "Clipboard",
                color: Color.primary.opacity(0.72),
                showsColorDot: false,
                selected: model.selectedCategoryID == nil
            ) {
                model.selectedCategoryID = nil
            }
            .fixedSize()

            if !model.categories.isEmpty {
                tagScroller

                if isOverflowing {
                    allTagsMenu
                }
            }

            Divider()
                .frame(height: 18)
                .opacity(0.2)
                .padding(.horizontal, 6)

            addTagButton
        }
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .frame(width: railWidth, height: 36)
        .background {
            ZStack {
                if #available(macOS 26.0, *) {
                    Color.clear
                        .glassEffect(.regular, in: CategoryBarElementShape())
                } else {
                    CategoryBarElementShape()
                        .fill(.regularMaterial)
                }

                CategoryBarElementShape()
                    .fill(
                        Color.primary.opacity(colorScheme == .dark ? 0.075 : 0.06)
                    )

                CategoryBarElementShape()
                    .strokeBorder(
                        Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.135),
                        lineWidth: 1
                    )
            }
        }
        .animation(.easeOut(duration: 0.16), value: railWidth)
    }

    private var tagScroller: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(model.categories) { category in
                        categoryButton(
                            title: category.name,
                            color: Color(categoryHex: category.colorHex),
                            selected: model.selectedCategoryID == category.id,
                            dropTargeted: targetedCategoryID == category.id
                        ) {
                            model.selectedCategoryID = category.id
                        }
                        .id(category.id)
                        .onDrop(
                            of: [UTType.passstClipboardRecord.identifier],
                            isTargeted: Binding(
                                get: { targetedCategoryID == category.id },
                                set: { isTargeted in
                                    targetedCategoryID = isTargeted ? category.id : nil
                                }
                            )
                        ) { providers in
                            assignDroppedRecord(from: providers, to: category)
                        }
                        .contextMenu {
                            Button("Delete Tag", role: .destructive) {
                                model.deleteCategory(category)
                            }
                        }
                    }
                }
                .padding(.horizontal, isOverflowing ? 8 : 0)
            }
            .scrollIndicators(.hidden)
            .mask {
                if isOverflowing {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.035),
                            .init(color: .black, location: 0.90),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                } else {
                    Color.black
                }
            }
            .onChange(of: model.selectedCategoryID) { _, selectedID in
                guard let selectedID else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(selectedID, anchor: .center)
                }
            }
        }
    }

    private var allTagsMenu: some View {
        Menu {
            Button {
                model.selectedCategoryID = nil
            } label: {
                Label(
                    "Clipboard",
                    systemImage: model.selectedCategoryID == nil
                        ? "checkmark"
                        : "clock.arrow.circlepath"
                )
            }

            Divider()

            ForEach(model.categories) { category in
                Button {
                    model.selectedCategoryID = category.id
                } label: {
                    Label(
                        category.name,
                        systemImage: model.selectedCategoryID == category.id
                            ? "checkmark"
                            : "tag"
                    )
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("All \(model.categories.count)")
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Color.primary.opacity(0.72))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(
                Color.primary.opacity(0.045),
                in: Capsule()
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(Color.primary)
        .fixedSize()
        .help("All tags")
        .accessibilityLabel("All tags")
    }

    private var rawPreferredWidth: CGFloat {
        let clipboardWidth = measuredButtonWidth("Clipboard", hasMarker: false)
        let tagWidths = model.categories.reduce(CGFloat.zero) { result, category in
            result + measuredButtonWidth(category.name, hasMarker: true)
        }
        let tagSpacing = CGFloat(max(0, model.categories.count - 1)) * 6
        let tagSegment = model.categories.isEmpty
            ? CGFloat.zero
            : 6 + tagWidths + tagSpacing
        return 10 + clipboardWidth + tagSegment + 13 + 1 + 12 + 28
    }

    private var isOverflowing: Bool {
        rawPreferredWidth > maximumWidth
    }

    private var railWidth: CGFloat {
        min(maximumWidth, rawPreferredWidth + (isOverflowing ? 70 : 0))
    }

    private func measuredButtonWidth(_ title: String, hasMarker: Bool) -> CGFloat {
        let font = NSFont.systemFont(
            ofSize: 14,
            weight: hasMarker ? .medium : .semibold
        )
        let textWidth = (title as NSString).size(
            withAttributes: [.font: font]
        ).width
        let leadingMark: CGFloat = hasMarker ? 17 : 0
        return ceil(textWidth) + leadingMark + 20
    }

    private var addTagButton: some View {
        Button {
            creatingTag = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.72))
                .frame(width: 28, height: 28)
                .background(
                    Color.primary.opacity(addTagHovered ? 0.07 : 0),
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .onHover { addTagHovered = $0 }
        .help("Create tag")
        .accessibilityLabel("Create tag")
        .popover(isPresented: $creatingTag, arrowEdge: .bottom) {
            tagCreator
        }
    }

    private var tagCreator: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Tag")
                .font(.headline)

            TextField("Name", text: $newTagName)
                .textFieldStyle(.roundedBorder)
                .focused($tagNameFocused)
                .onSubmit(createTag)

            HStack(spacing: 9) {
                ForEach(ClipboardCategory.palette, id: \.self) { colorHex in
                    Button {
                        newTagColor = colorHex
                    } label: {
                        Circle()
                            .fill(Color(categoryHex: colorHex))
                            .frame(width: 20, height: 20)
                            .overlay {
                                if newTagColor == colorHex {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    creatingTag = false
                    resetTagCreator()
                }
                Button("Create", action: createTag)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        newTagName
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty
                    )
            }
        }
        .padding(16)
        .frame(width: 280)
        .onAppear {
            Task { @MainActor in
                await Task.yield()
                tagNameFocused = true
            }
        }
    }

    private func createTag() {
        guard model.addCategory(
            name: newTagName,
            colorHex: newTagColor
        ) != nil else {
            return
        }
        creatingTag = false
        resetTagCreator()
    }

    private func resetTagCreator() {
        newTagName = ""
        newTagColor = ClipboardCategory.palette[4]
    }

    private func categoryButton(
        title: String,
        color: Color,
        systemImage: String? = nil,
        showsColorDot: Bool = true,
        selected: Bool,
        dropTargeted: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let identifier = systemImage == nil ? title : "clipboard"
        let hovered = hoveredCategoryID == identifier

        return Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 14)
                } else if showsColorDot {
                    Circle()
                        .fill(color)
                        .frame(width: 9, height: 9)
                }

                Text(title)
                    .lineLimit(1)
            }
            .font(.system(size: 14, weight: selected ? .semibold : .medium))
            .foregroundStyle(
                selected
                    ? Color.primary.opacity(0.92)
                    : Color.primary.opacity(0.68)
            )
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                dropTargeted
                    ? color.opacity(0.22)
                    : selected
                        ? PassstStyle.brandViolet.opacity(
                            colorScheme == .dark ? 0.18 : 0.12
                        )
                        : Color.primary.opacity(hovered ? 0.06 : 0),
                in: CategoryBarElementShape()
            )
            .overlay {
                if dropTargeted {
                    CategoryBarElementShape()
                        .stroke(color.opacity(0.9), lineWidth: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered in
            hoveredCategoryID = isHovered ? identifier : nil
        }
        .help(title)
        .animation(.easeOut(duration: 0.12), value: dropTargeted)
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    private func assignDroppedRecord(
        from providers: [NSItemProvider],
        to category: ClipboardCategory
    ) -> Bool {
        guard let provider = providers.first(
            where: {
                $0.hasItemConformingToTypeIdentifier(
                    UTType.passstClipboardRecord.identifier
                )
            }
        ) else {
            return false
        }

        provider.loadDataRepresentation(
            forTypeIdentifier: UTType.passstClipboardRecord.identifier
        ) { data, _ in
            guard let data,
                  let value = String(data: data, encoding: .utf8),
                  let recordID = UUID(uuidString: value)
            else {
                return
            }
            Task { @MainActor in
                model.assign(recordID: recordID, to: category)
            }
        }
        return true
    }
}
