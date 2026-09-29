import AppKit
import Penumbra
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
        /// Floor for the titlebar row, which otherwise matches the system titlebar's height.
        static let titlebarMinHeight = 36.0
        static let tabHeight = 32.0
        static let iconButton = 26.0
        static let statusBarHeight = 36.0
        static let terminalDefaultHeight = 220.0
        static let terminalMinHeight = 120.0
        static let terminalMaxHeight = 600.0
        /// Narrowest the editor column may get when the side panels are dragged against it.
        static let editorMinLength = 240.0
        /// Shortest the editor island may get when the terminal is dragged up against it.
        static let editorMinHeight = 120.0
        /// Smallest width or height of one editor pane in a split.
        static let editorPaneMinLength = 120.0
        static let welcomeMaxWidth = 520.0
        /// Gap between the floating panels, and between them and the window edge. Resize handles
        /// live in these gaps.
        static let panelGap = 6.0
        static let firstRunGuideWidth = 640.0
        static let firstRunGuideHeight = 428.0
        static let firstRunGuideRailWidth = 168.0
        /// Space reserved so traffic lights do not overlap the toolbar row.
        static let trafficLightsInset = 78.0
        static let titlebarButton = 28.0
        static let dirtyDotSize = 5.0
    }

    enum Radius {
        static let control = 6.0
        static let card = 8.0
        static let panel = 10.0
    }

    enum IconSize {
        static let breadcrumbChevron = 8.0
        static let toolbarGlyph = 12.0
        static let titlebarGlyph = 14.0
    }

    enum Typography {
        private static var family: String { IDEUIFonts.currentFamilyName }

        private static func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
            IDEUIFonts.font(familyName: family, size: size, weight: weight)
        }

        private static func sized(_ base: CGFloat) -> CGFloat {
            IDEUIFonts.scaledSize(base)
        }

        static var brandTitle: Font { font(size: sized(28), weight: .semibold) }
        static var sectionHeader: Font { font(size: sized(12), weight: .semibold) }
        static var body: Font { font(size: sized(15)) }
        static var caption: Font { font(size: sized(12)) }
        static var monoCaption: Font { font(size: sized(12)) }
        static var monoSmall: Font { font(size: sized(11)) }
        static var tabLabel: Font { font(size: sized(12)) }
        static var sidebarHeader: Font { font(size: sized(11), weight: .semibold) }
        static var titlebarTitle: Font { font(size: sized(13), weight: .semibold) }
        static var panelTab: Font { font(size: sized(12), weight: .medium) }
    }

    enum ColorToken {
        /// The window frame the floating panels sit on: titlebar, stripes, gaps, status bar.
        static let window = Color(hex: 0x0B0B0D)
        /// Floating panel (card) fill and outline.
        static let panel = Color(hex: 0x18181B)
        static let panelBorder = Color.white.opacity(0.05)
        static let card = Color(hex: 0x27272B)
        static let workbench = Color(hex: 0x101012)
        static let sidebar = Color(hex: 0x18181B)
        static let editor = Color(hex: 0x101012)
        static let tabBar = Color(hex: 0x18181B)
        static let tabActive = Color(hex: 0x2A2A30)
        static let tabInactive = Color.clear
        static let tabHover = Color(hex: 0x1C1C20)
        static let controlHover = Color.white.opacity(0.06)
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
        static let window = ns(0x0B0B0D)
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

enum IDEUIFonts {
    static let defaultFamilyName = "SF Compact"
    static let defaultFontSize: Double = 13
    private(set) nonisolated(unsafe) static var currentFamilyName = defaultFamilyName
    private(set) nonisolated(unsafe) static var currentFontSize = defaultFontSize

    static let familyNames: [String] = {
        NSFontManager.shared.availableFontFamilies
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }()

    static func choices(including current: String) -> [String] {
        if familyNames.contains(current) {
            return familyNames
        }
        return [current] + familyNames
    }

    static func setCurrentFamilyName(_ name: String) {
        currentFamilyName = name
    }

    static func setCurrentFontSize(_ size: Double) {
        currentFontSize = size
    }

    static func scaledSize(_ base: CGFloat) -> CGFloat {
        base * CGFloat(currentFontSize / defaultFontSize)
    }

    static func nsFont(familyName: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: familyName,
            .size: size,
            .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue]
        ])
        if let font = NSFont(descriptor: descriptor, size: size) {
            return font
        }
        return NSFont.systemFont(ofSize: size, weight: weight)
    }

    static func font(familyName: String, size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font(nsFont(familyName: familyName, size: size, weight: nsWeight(weight)))
    }

    private static func nsWeight(_ weight: Font.Weight) -> NSFont.Weight {
        switch weight {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }
}

extension View {
    /// Floating-panel chrome: the content becomes a rounded card sitting on the window frame
    /// (`ColorToken.window`), with a faint outline so adjacent cards separate without hairlines.
    func idePanel(fill: Color = IDEAppearance.ColorToken.panel) -> some View {
        let shape = RoundedRectangle(cornerRadius: IDEAppearance.Radius.panel, style: .continuous)
        return background(fill)
            .clipShape(shape)
            .overlay {
                shape
                    .strokeBorder(IDEAppearance.ColorToken.panelBorder, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

/// A side panel's title, drawn as the selected tab of a tab strip (the panel is its only tab).
struct IDEPanelTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(IDEAppearance.Typography.panelTab)
            .foregroundStyle(IDEAppearance.ColorToken.foreground)
            .lineLimit(1)
            .padding(.horizontal, IDEAppearance.Spacing.sm)
            .padding(.vertical, 3)
            .background(
                IDEAppearance.ColorToken.card,
                in: RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous)
            )
            .accessibilityAddTraits(.isHeader)
    }
}

/// File-type SF Symbol lookup shared by the file tree, Find in Files rows and the Go to File
/// palette, so a given extension always gets the same glyph wherever a file is listed.
enum IDEFileIcon {
    private static let gradleFilenames: Set<String> = [
        "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"
    ]

    nonisolated static func systemName(forFilename filename: String) -> String {
        if gradleFilenames.contains(filename) { return "hammer" }
        switch (filename as NSString).pathExtension.lowercased() {
        case "swift": return "swift"
        case "js", "jsx", "ts", "tsx": return "curlybraces"
        case "json": return "curlybraces.square"
        case "java": return "cup.and.saucer"
        case "kt", "kts": return "k.square"
        case "md", "markdown": return "text.book.closed"
        case "py": return "chevron.left.forwardslash.chevron.right"
        case "http", "rest": return "globe"
        case "sh", "zsh", "bash": return "terminal"
        case "yaml", "yml": return "list.bullet.indent"
        case "xml", "html", "htm": return "chevron.left.forwardslash.chevron.right"
        case "properties", "toml", "ini", "conf", "env": return "gearshape"
        case "bmp", "gif", "heic", "heif", "icns", "ico", "jpeg", "jpg", "png", "tiff", "tif", "webp":
            return "photo"
        default: return "doc.text"
        }
    }

    /// The Go to File row glyph: a lettered circle for JVM sources (IntelliJ's class icon) and the
    /// shared per-extension symbol, tinted, for everything else.
    nonisolated static func paletteIcon(forFilename filename: String) -> PaletteIcon {
        if gradleFilenames.contains(filename) { return PaletteIcon(systemName: "hammer", tint: .green) }
        switch (filename as NSString).pathExtension.lowercased() {
        case "java": return PaletteIcon(systemName: "c.circle.fill", tint: .blue)
        case "kt", "kts": return PaletteIcon(systemName: "k.circle.fill", tint: .purple)
        case "class": return PaletteIcon(systemName: "c.circle", tint: .secondary)
        case "swift": return PaletteIcon(systemName: "swift", tint: .orange)
        case "http", "rest": return PaletteIcon(systemName: "globe", tint: .blue)
        case "sh", "zsh", "bash": return PaletteIcon(systemName: "terminal", tint: .green)
        case "yaml", "yml": return PaletteIcon(systemName: "list.bullet.indent", tint: .green)
        case "xml", "html", "htm", "json": return PaletteIcon(systemName: systemName(forFilename: filename), tint: .orange)
        case "bmp", "gif", "heic", "heif", "icns", "ico", "jpeg", "jpg", "png", "tiff", "tif", "webp":
            return PaletteIcon(systemName: "photo", tint: .purple)
        default: return PaletteIcon(systemName: systemName(forFilename: filename), tint: .secondary)
        }
    }
}
