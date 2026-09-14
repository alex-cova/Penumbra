import AppKit
import SwiftUI

/// Shared design tokens for the MacExample shell.
/// VARIANCE 7 · MOTION 3 · DENSITY 8
enum IDEAppearance {
    enum Spacing {
        static let xs = 4.0
        static let sm = 8.0
        static let md = 12.0
        static let lg = 16.0
        static let sidebarWidth = 220.0
        static let sidebarMinWidth = 160.0
        static let sidebarMaxWidth = 420.0
        static let tabHeight = 36.0
        static let statusBarHeight = 24.0
        /// Space reserved so traffic lights do not overlap the first chrome row.
        static let trafficLightsInset = 78.0
    }

    enum Radius {
        static let control = 6.0
    }

    enum ColorToken {
        static let workbench = Color(hex: 0x101012)
        static let sidebar = Color(hex: 0x18181B)
        static let editor = Color(hex: 0x101012)
        static let tabBar = Color(hex: 0x18181B)
        static let tabActive = Color(hex: 0x222226)
        static let tabInactive = Color.clear
        static let tabHover = Color(hex: 0x1C1C20)
        static let statusBar = Color(hex: 0x18181B)
        static let border = Color.white.opacity(0.08)
        static let accent = Color(hex: 0x74ADE8)
        static let foreground = Color(hex: 0xECEDEE)
        static let muted = Color(hex: 0x8A8F98)
        static let selection = Color(hex: 0x74ADE8).opacity(0.18)
    }

    enum NSToken {
        static let workbench = ns(0x101012)
        static let editor = ns(0x101012)
        static let sidebar = ns(0x18181B)
        static let border = NSColor.white.withAlphaComponent(0.08)
        static let accent = ns(0x74ADE8)
        static let foreground = ns(0xECEDEE)
        static let muted = ns(0x8A8F98)
        static let selection = ns(0x74ADE8).withAlphaComponent(0.18)

        private static func ns(_ hex: UInt32) -> NSColor {
            NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        }
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}
