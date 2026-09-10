import AppKit
import SwiftUI

enum PassstStyle {
    static var panelCornerRadius: CGFloat {
        if #available(macOS 26.0, *) {
            26
        } else {
            8
        }
    }
    static let toolbarHeight: CGFloat = 60

    static let cardWidth: CGFloat = 244
    static let cardHeight: CGFloat = 228
    static let cardHeaderHeight: CGFloat = 60
    static var cardCornerRadius: CGFloat {
        if #available(macOS 26.0, *) {
            20
        } else {
            8
        }
    }
    static let cardSpacing: CGFloat = 12

    static let panelHorizontalPadding: CGFloat = 20
    static let historyTopPadding: CGFloat = 10
    static let historyBottomPadding: CGFloat = 22

    static let brandBlue = Color(red: 0.18, green: 0.45, blue: 1.00)
    static let brandViolet = Color(red: 0.48, green: 0.34, blue: 0.98)
    static let brandCyan = Color(red: 0.13, green: 0.78, blue: 0.92)

    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [brandCyan, brandBlue, brandViolet],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

extension ClipboardContentKind {
    var cardAccent: Color {
        switch self {
        case .text, .richText:
            Color(red: 0.47, green: 0.36, blue: 0.96)
        case .code:
            Color(red: 0.10, green: 0.52, blue: 1.00)
        case .link:
            Color(red: 0.04, green: 0.69, blue: 0.53)
        case .image:
            Color(red: 0.96, green: 0.25, blue: 0.47)
        case .color:
            Color(red: 0.05, green: 0.67, blue: 0.72)
        case .files:
            Color(red: 0.58, green: 0.34, blue: 0.94)
        case .mixed:
            Color(red: 0.34, green: 0.43, blue: 0.58)
        }
    }
}

extension Color {
    init(categoryHex value: String) {
        self.init(nsColor: NSColor(categoryHex: value))
    }
}

extension NSColor {
    convenience init(categoryHex value: String) {
        let hex = value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let raw = UInt64(hex, radix: 16) ?? 0x0A84FF
        self.init(
            red: CGFloat((raw >> 16) & 0xFF) / 255,
            green: CGFloat((raw >> 8) & 0xFF) / 255,
            blue: CGFloat(raw & 0xFF) / 255,
            alpha: 1
        )
    }
}
