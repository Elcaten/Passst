import AppKit
import QuartzCore
import SwiftUI

enum PanelNavigationBoundary {
    case first
    case last
}

enum PanelKeyCommand {
    case move(delta: Int, extending: Bool)
    case moveToBoundary(PanelNavigationBoundary, extending: Bool)
    case copy
    case paste(plainText: Bool)
    case preview
    case escape
    case focusSearch
    case selectAll
    case delete
}

final class PassstPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PassstHostingView<Content: View>: NSHostingView<Content> {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
final class PanelController {
    private enum PresentationState {
        case hidden
        case presenting
        case presented
        case dismissing
    }

    private unowned let model: AppModel
    private let panel: PassstPanel
    private let hostingView: PassstHostingView<PanelRootView>
    private var state: PresentationState = .hidden
    private var keyMonitor: Any?
    private var outsideClickMonitor: Any?
    private var scrollWheelMonitor: Any?
    private var pendingCloseCompletions: [() -> Void] = []

    private(set) var previouslyActiveApplication: NSRunningApplication?

    var isPresented: Bool {
        state != .hidden
    }

    var shouldPresentOnToggle: Bool {
        state == .hidden || state == .dismissing
    }

    init(model: AppModel) {
        self.model = model
        panel = PassstPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        hostingView = PassstHostingView(rootView: PanelRootView(model: model))

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle
        ]
        panel.contentView = hostingView
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.masksToBounds = false
    }

    func present() {
        if state == .presented || state == .presenting {
            close()
            return
        }

        if state == .dismissing {
            pendingCloseCompletions.removeAll()
            panel.ignoresMouseEvents = true
            state = .presenting
            animate(
                toTranslationY: 0,
                toOpacity: 1,
                opening: true
            ) { [weak self] in
                guard let self, self.state == .presenting else { return }
                self.state = .presented
                self.panel.ignoresMouseEvents = false
            }
            return
        }

        previouslyActiveApplication = NSWorkspace.shared.frontmostApplication.flatMap { app in
            app.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : app
        }
        pendingCloseCompletions.removeAll()

        let finalFrame = panelFrame()
        panel.setFrame(finalFrame, display: true)
        prepareLayerForOpening()
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        panel.makeKey()
        model.isSearchFocused = false
        installEventMonitors()

        state = .presenting
        animate(
            toTranslationY: 0,
            toOpacity: 1,
            opening: true
        ) { [weak self] in
            guard let self, self.state == .presenting else { return }
            self.state = .presented
            self.panel.ignoresMouseEvents = false
        }
    }

    func close(completion: (() -> Void)? = nil) {
        if let completion {
            pendingCloseCompletions.append(completion)
        }
        guard state != .hidden, state != .dismissing else { return }

        state = .dismissing
        panel.ignoresMouseEvents = true
        animate(
            toTranslationY: hiddenTranslationY,
            toOpacity: 0.62,
            opening: false
        ) { [weak self] in
            guard let self, self.state == .dismissing else { return }
            self.panel.orderOut(nil)
            self.state = .hidden
            self.removeEventMonitors()
            self.resetPresentationLayer()

            let completions = self.pendingCloseCompletions
            self.pendingCloseCompletions.removeAll()
            completions.forEach { $0() }
        }
    }

    private func panelFrame() -> NSRect {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        let screenFrame = screen.frame
        let inset: CGFloat = 8
        return NSRect(
            x: screenFrame.minX + inset,
            y: screenFrame.minY + inset,
            width: screenFrame.width - (inset * 2),
            height: min(320, screenFrame.height - (inset * 2))
        )
    }

    private func animate(
        toTranslationY targetY: CGFloat,
        toOpacity targetOpacity: Float,
        opening: Bool,
        completion: @escaping () -> Void
    ) {
        guard let layer = hostingView.layer else {
            completion()
            return
        }

        let presentation = layer.presentation()
        let currentY = (
            presentation?.value(forKeyPath: "transform.translation.y") as? NSNumber
        )?.doubleValue ?? (
            layer.value(forKeyPath: "transform.translation.y") as? NSNumber
        )?.doubleValue ?? (opening ? -panel.frame.height : 0)
        let currentOpacity = presentation?.opacity ?? layer.opacity
        layer.removeAllAnimations()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(targetY, forKeyPath: "transform.translation.y")
        layer.opacity = targetOpacity
        CATransaction.commit()

        let motionDuration: CFTimeInterval = model.reduceMotion
            ? (opening ? 0.14 : 0.11)
            : (opening ? 0.26 : 0.18)
        let translation = CABasicAnimation(keyPath: "transform.translation.y")
        translation.fromValue = currentY
        translation.toValue = targetY
        translation.duration = motionDuration
        translation.timingFunction = opening
            ? CAMediaTimingFunction(controlPoints: 0.16, 0.82, 0.24, 1)
            : CAMediaTimingFunction(controlPoints: 0.42, 0, 0.92, 0.58)

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = currentOpacity
        opacity.toValue = targetOpacity
        opacity.duration = model.reduceMotion ? 0.12 : motionDuration
        opacity.timingFunction = opening
            ? CAMediaTimingFunction(controlPoints: 0.18, 0.78, 0.22, 1)
            : CAMediaTimingFunction(name: .easeIn)

        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        layer.add(translation, forKey: "passst.translation")
        layer.add(opacity, forKey: "passst.opacity")
        CATransaction.commit()
    }

    private func resetPresentationLayer() {
        guard let layer = hostingView.layer else { return }
        layer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(0, forKeyPath: "transform.translation.y")
        layer.opacity = 1
        CATransaction.commit()
    }

    private var hiddenTranslationY: CGFloat {
        -panel.frame.height - 12
    }

    private func prepareLayerForOpening() {
        guard let layer = hostingView.layer else { return }
        layer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(hiddenTranslationY, forKeyPath: "transform.translation.y")
        layer.opacity = 0.62
        CATransaction.commit()
    }

    private func installEventMonitors() {
        removeEventMonitors()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            return self.routeKeyEvent(event) ? nil : event
        }

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.model.closePanel()
            }
        }

        scrollWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
            [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
                  let scrollView = self.horizontalScrollView(in: self.hostingView)
            else {
                return event
            }

            let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 11
            var origin = scrollView.contentView.bounds.origin
            origin.x -= event.scrollingDeltaY * multiplier
            let maximumX = max(
                0,
                (scrollView.documentView?.bounds.width ?? 0)
                    - scrollView.contentView.bounds.width
            )
            origin.x = min(max(0, origin.x), maximumX)
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            return nil
        }
    }

    private func removeEventMonitors() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        if let scrollWheelMonitor {
            NSEvent.removeMonitor(scrollWheelMonitor)
            self.scrollWheelMonitor = nil
        }
    }

    private func routeKeyEvent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCommand = flags.contains(.command)
        let hasControl = flags.contains(.control)
        let hasShift = flags.contains(.shift)
        let characters = event.charactersIgnoringModifiers?.lowercased()

        if (hasCommand || hasControl), event.keyCode == 8 || characters == "c" {
            model.handle(.copy)
            return true
        }
        if hasCommand, characters == "f" {
            model.handle(.focusSearch)
            return true
        }
        if hasCommand, characters == "a" {
            model.handle(.selectAll)
            return true
        }

        if event.keyCode == 48 {
            model.isSearchFocused.toggle()
            return true
        }

        switch event.keyCode {
        case 123:
            guard !searchFieldHasKeyboardFocus else { return false }
            if hasCommand {
                model.handle(.moveToBoundary(.first, extending: hasShift))
            } else {
                model.handle(.move(delta: -1, extending: hasShift))
            }
            return true
        case 124:
            guard !searchFieldHasKeyboardFocus else { return false }
            if hasCommand {
                model.handle(.moveToBoundary(.last, extending: hasShift))
            } else {
                model.handle(.move(delta: 1, extending: hasShift))
            }
            return true
        case 36, 76:
            guard !searchFieldHasKeyboardFocus else { return false }
            model.handle(.paste(plainText: hasShift))
            return true
        case 49:
            if model.isSearchFocused {
                if searchFieldHasKeyboardFocus {
                    return false
                }
                model.beginSearch(with: " ")
                return true
            }
            model.handle(.preview)
            return true
        case 53:
            model.handle(.escape)
            return true
        case 51, 117:
            if model.isSearchFocused {
                if searchFieldHasKeyboardFocus {
                    return false
                }
                model.deleteLastSearchCharacter()
                return true
            }
            model.handle(.delete)
            return true
        default:
            let disallowedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
            if flags.intersection(disallowedModifiers).isEmpty,
               let characters = event.characters,
               characters.unicodeScalars.allSatisfy({
                   !CharacterSet.controlCharacters.contains($0)
               }) {
                if searchFieldHasKeyboardFocus {
                    return false
                }
                model.beginSearch(with: characters)
                return true
            }
            return false
        }
    }

    private func horizontalScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView,
           let documentView = scrollView.documentView,
           documentView.bounds.width > scrollView.contentView.bounds.width {
            return scrollView
        }
        for subview in view.subviews {
            if let match = horizontalScrollView(in: subview) {
                return match
            }
        }
        return nil
    }

    private var searchFieldHasKeyboardFocus: Bool {
        panel.firstResponder is NSTextView
    }
}
