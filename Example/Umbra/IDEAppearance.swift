import AppKit
import SwiftUI

/// Shared design tokens for the Umbra shell.
/// VARIANCE 7 · DENSITY 8
enum IDEAppearance {
    enum Spacing {
        static let xs = 4.0
        static let sm = 8.0
        static let md = 12.0
        static let lg = 16.0
        static let xl = 24.0
        static let xxl = 32.0
        static let sidebarWidth = 220.0
        static let sidebarMinWidth = 160.0
        static let sidebarMaxWidth = 420.0
        static let toolbarHeight = 38.0
        static let tabHeight = 32.0
        static let iconButton = 26.0
        static let statusBarHeight = 24.0
        static let terminalDefaultHeight = 220.0
        static let terminalMinHeight = 120.0
        static let terminalMaxHeight = 600.0
        static let welcomeMaxWidth = 520.0
        static let firstRunGuideWidth = 640.0
        static let firstRunGuideHeight = 428.0
        static let firstRunGuideRailWidth = 168.0
        static let settingsWidth = 480.0
        static let settingsMinHeight = 520.0
        /// Space reserved so traffic lights do not overlap the toolbar row.
        static let trafficLightsInset = 78.0
        static let dirtyDotSize = 5.0
    }

    enum Radius {
        static let control = 6.0
        static let card = 8.0
    }

    enum IconSize {
        static let breadcrumbChevron = 8.0
        static let toolbarGlyph = 12.0
    }

    enum Typography {
        static let brandTitle = Font.system(.title, design: .default).weight(.semibold)
        static let sectionHeader = Font.system(.caption, design: .default).weight(.semibold)
        static let body = Font.system(.subheadline)
        static let caption = Font.system(.caption)
        static let monoCaption = Font.system(.caption, design: .monospaced)
        static let monoSmall = Font.system(size: 11, design: .monospaced)
        static let tabLabel = Font.system(size: 12)
        static let sidebarHeader = Font.system(size: 11, weight: .semibold)
    }

    enum ColorToken {
        static let workbench = Color(hex: 0x101012)
        static let sidebar = Color(hex: 0x18181B)
        static let editor = Color(hex: 0x101012)
        static let toolbar = Color(hex: 0x1B1B1F)
        static let tabBar = Color(hex: 0x18181B)
        static let tabActive = Color(hex: 0x2A2A30)
        static let tabInactive = Color.clear
        static let tabHover = Color(hex: 0x1C1C20)
        static let controlHover = Color.white.opacity(0.06)
        static let statusBar = Color(hex: 0x18181B)
        static let border = Color.white.opacity(0.08)
        static let accent = Color(hex: 0x74ADE8)
        static let run = Color(hex: 0x3DDC84)
        static let foreground = Color(hex: 0xECEDEE)
        static let muted = Color(hex: 0x8A8F98)
        static let selection = Color(hex: 0x74ADE8).opacity(0.18)
        static let error = Color(hex: 0xE5484D)
        static let gitModified = Color(hex: 0xE2C08D)
        static let gitAdded = Color(hex: 0x73C991)
        static let gitUntracked = Color(hex: 0x73C991)
        static let gitConflict = Color(hex: 0xE5484D)
        static let gitIgnored = Color(hex: 0x8A8F98).opacity(0.55)
        static let sourceRoot = Color(hex: 0x74ADE8)
        static let testSourceRoot = Color(hex: 0x73C991)
        static let resourcesFolder = Color(hex: 0xD7A35B)
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
        static let error = ns(0xE5484D)

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

/// File-type SF Symbol lookup shared by the file tree and Find in Files rows, so a given
/// extension always gets the same glyph wherever a file is listed.
enum IDEFileIcon {
    static func systemName(forFilename filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "swift": "swift"
        case "js", "jsx", "ts", "tsx": "curlybraces"
        case "json": "curlybraces.square"
        case "java": "cup.and.saucer"
        case "kt", "kts": "k.square"
        case "md", "markdown": "text.book.closed"
        case "py": "chevron.left.forwardslash.chevron.right"
        case "bmp", "gif", "heic", "heif", "icns", "ico", "jpeg", "jpg", "png", "tiff", "tif", "webp":
            "photo"
        default: "doc.text"
        }
    }
}
