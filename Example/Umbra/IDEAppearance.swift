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
        static let toolbarHeight = 38.0
        static let tabHeight = 32.0
        static let iconButton = 26.0
        static let toolWindowStripeWidth = 40.0
        static let toolWindowButton = 30.0
        static let statusBarHeight = 24.0
        static let terminalDefaultHeight = 220.0
        static let terminalMinHeight = 120.0
        static let terminalMaxHeight = 600.0
        static let welcomeMaxWidth = 520.0
        static let firstRunGuideWidth = 640.0
        static let firstRunGuideHeight = 428.0
        static let firstRunGuideRailWidth = 168.0
        static let settingsWidth = 640.0
        static let settingsIdealWidth = 720.0
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
        static let toolWindowGlyph = 15.0
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
        static let statusBar = Color(hex: 0x1B1B1F)
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

/// AppKit-backed vibrancy for shell chrome. Falls back to a solid fill when Reduce Transparency is on.
struct IDEVisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .withinWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
    }
}

/// Pre–macOS 26 frosted shell background: blurs adjacent content, keeps the dark IDE tint, and draws
/// a hairline on the inner edge when used for a tool-window stripe. On macOS 26+, tool-window
/// stripes use Liquid Glass (`GlassEffectContainer` / `.glassEffect`) instead.
struct IDEChromeGlassBackground: View {
    enum InnerEdge {
        case leading, trailing
    }

    var innerEdge: InnerEdge?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            IDEAppearance.ColorToken.toolbar
                .overlay { innerEdgeHairline }
        } else {
            ZStack {
                IDEVisualEffectBackground(material: .sidebar, blendingMode: .withinWindow)
                IDEAppearance.ColorToken.toolbar.opacity(0.32)
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.05),
                        Color.clear,
                        Color.black.opacity(0.06),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .overlay { innerEdgeHairline }
        }
    }

    @ViewBuilder
    private var innerEdgeHairline: some View {
        if let innerEdge {
            Rectangle()
                .fill(IDEAppearance.ColorToken.border)
                .frame(width: 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: innerEdge == .leading ? .leading : .trailing)
        }
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
