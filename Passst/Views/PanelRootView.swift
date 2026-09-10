import AppKit
import SwiftUI

struct PanelRootView: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var historyOverflow = HistoryScrollOverflow()

    var body: some View {
        ZStack(alignment: .top) {
            panelBackground

            VStack(spacing: 0) {
                PanelToolbar(model: model)
                    .frame(height: PassstStyle.toolbarHeight)
                    .zIndex(30)

                history
            }

            if let previewedID = model.previewedID,
               let record = model.records.first(where: { $0.id == previewedID }) {
                PreviewOverlay(
                    model: model,
                    record: record,
                    payload: model.previewPayload
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .zIndex(10)
            }

            if let notice = model.notice {
                NoticeView(notice: notice)
                    .padding(.top, PassstStyle.toolbarHeight - 2)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(20)
            }
        }
        .clipShape(panelShape)
        .overlay {
            panelShape
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.23 : 0.48),
                            PassstStyle.brandBlue.opacity(0.16),
                            Color.white.opacity(colorScheme == .dark ? 0.08 : 0.18)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.9
                )
                .padding(0.5)
        }
        .tint(PassstStyle.brandBlue)
        .ignoresSafeArea()
    }

    private var panelShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: PassstStyle.panelCornerRadius,
            style: .continuous
        )
    }

    private var panelBackground: some View {
        ZStack {
            if #available(macOS 26.0, *) {
                Color.clear
                    .glassEffect(
                        .regular.tint(PassstStyle.brandBlue.opacity(0.025)),
                        in: .rect(cornerRadius: PassstStyle.panelCornerRadius)
                    )
            } else {
                VisualEffectView(material: .underWindowBackground)
                    .opacity(colorScheme == .dark ? 0.78 : 0.72)
            }

            Color.black.opacity(colorScheme == .dark ? 0.06 : 0)
            LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.035 : 0.10),
                    Color.clear,
                    PassstStyle.brandCyan.opacity(colorScheme == .dark ? 0.055 : 0.028)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    PassstStyle.brandViolet.opacity(colorScheme == .dark ? 0.10 : 0.055),
                    Color.clear
                ],
                center: .bottomLeading,
                startRadius: 0,
                endRadius: 460
            )
        }
    }

    private var history: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: PassstStyle.cardSpacing) {
                        if model.records.isEmpty, !model.isLoading {
                            emptyState
                        }

                        ForEach(model.records) { record in
                            ClipboardCardView(
                                model: model,
                                record: record
                            )
                            .id(record.id)
                            .transition(
                                .asymmetric(
                                    insertion: .opacity.combined(with: .offset(x: 12)),
                                    removal: .opacity.combined(with: .scale(scale: 0.985))
                                )
                            )
                            .onAppear {
                                model.loadMoreIfNeeded(visibleRecord: record)
                            }
                        }

                        if model.isLoading && (model.records.isEmpty || model.hasMore) {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 60)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, PassstStyle.panelHorizontalPadding)
                    .padding(.top, PassstStyle.historyTopPadding)
                    .padding(.bottom, PassstStyle.historyBottomPadding)
                    .background {
                        GeometryReader { contentGeometry in
                            Color.clear.preference(
                                key: HistoryContentFramePreferenceKey.self,
                                value: contentGeometry.frame(
                                    in: .named(HistoryCoordinateSpace.name)
                                )
                            )
                        }
                    }
                }
                .coordinateSpace(name: HistoryCoordinateSpace.name)
                .scrollIndicators(.hidden)
                .modifier(
                    HistoryOverflowTrackingModifier(
                        overflow: $historyOverflow,
                        viewportWidth: geometry.size.width
                    )
                )
                .mask {
                    historyMask(
                        showsLeadingFade: historyOverflow.canScrollBackward,
                        showsTrailingFade: historyOverflow.canScrollForward
                    )
                }
                .onChange(of: model.instantHistoryScrollRequest) { _, request in
                    guard let request else { return }
                    scrollImmediately(to: request.targetID, using: proxy)
                }
                .onChange(of: model.selection.focusedID) { _, focusedID in
                    guard let focusedID else { return }
                    guard model.shouldAnimateHistoryScroll(to: focusedID) else {
                        scrollImmediately(to: focusedID, using: proxy)
                        return
                    }
                    withAnimation(
                        model.reduceMotion ? .easeOut(duration: 0.1) : .smooth(duration: 0.16)
                    ) {
                        proxy.scrollTo(focusedID)
                    }
                }
            }
        }
    }

    private func historyMask(
        showsLeadingFade: Bool,
        showsTrailingFade: Bool
    ) -> some View {
        HStack(spacing: 0) {
            if showsLeadingFade {
                LinearGradient(
                    colors: [.clear, .black],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 56)
            }

            Color.black

            if showsTrailingFade {
                LinearGradient(
                    colors: [.black, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 56)
            }
        }
        .animation(.easeOut(duration: 0.12), value: showsLeadingFade)
        .animation(.easeOut(duration: 0.12), value: showsTrailingFade)
    }

    private func scrollImmediately(to id: UUID, using proxy: ScrollViewProxy) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(id, anchor: .leading)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(
                systemName: model.searchQuery.isEmpty && !model.hasActiveSearchFilters
                    ? "clipboard"
                    : "magnifyingglass"
            )
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text(emptyStateTitle)
                .font(.system(size: 15, weight: .semibold))
            Text(
                emptyStateMessage
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .frame(width: 330, height: 210)
    }

    private var emptyStateTitle: String {
        if !model.searchQuery.isEmpty || model.hasActiveSearchFilters {
            return "No matches"
        }
        if model.selectedCategoryID != nil {
            return "No items with this tag"
        }
        return "Copy something to begin"
    }

    private var emptyStateMessage: String {
        if !model.searchQuery.isEmpty || model.hasActiveSearchFilters {
            return "Try another query or remove a filter."
        }
        if model.selectedCategoryID != nil {
            return "Drag a card onto this tag, or assign it from the context menu."
        }
        return "Passst keeps the original clipboard formats."
    }
}

private enum HistoryCoordinateSpace {
    static let name = "historyScroll"
}

private struct HistoryScrollOverflow: Equatable {
    var canScrollBackward = false
    var canScrollForward = false
}

private struct HistoryContentFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private struct HistoryOverflowTrackingModifier: ViewModifier {
    @Binding var overflow: HistoryScrollOverflow
    let viewportWidth: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: HistoryScrollOverflow.self) { geometry in
                HistoryScrollOverflow(
                    canScrollBackward: geometry.visibleRect.minX > 1,
                    canScrollForward: geometry.visibleRect.maxX
                        < geometry.contentSize.width - 1
                )
            } action: { _, newValue in
                overflow = newValue
            }
        } else {
            content.onPreferenceChange(HistoryContentFramePreferenceKey.self) { frame in
                overflow = HistoryScrollOverflow(
                    canScrollBackward: frame.minX < -1,
                    canScrollForward: frame.maxX > viewportWidth + 1
                )
            }
        }
    }
}

private struct NoticeView: View {
    let notice: PanelNotice

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: notice.symbol)
            Text(notice.message)
                .lineLimit(2)
        }
        .font(.system(size: 12.5, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            notice.isError
                ? Color.red.opacity(0.92)
                : Color.black.opacity(0.78),
            in: Capsule()
        )
        .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
        .frame(maxWidth: 620)
    }
}
