import AppKit
import Penumbra

/// Builds and holds the active Penumbra editor theme from user preferences.
final class IDEEditorTheme: @unchecked Sendable {
    static let shared = IDEEditorTheme()

    private var theme: PaletteTheme

    var current: PaletteTheme { theme }

    private init() {
        let palette = ThemeCatalog.palette(id: ThemeCatalog.defaultDarkID, fallbackDark: true)
        theme = PaletteTheme(
            size: 13,
            palette: palette,
            font: IDEEditorFonts.nsFont(familyName: IDEEditorFonts.defaultFamilyName, size: 13)
        )
    }

    func rebuild(themeID: String, fontSize: Double, fontName: String) {
        let palette = ThemeCatalog.palette(id: themeID, fallbackDark: true)
        theme = PaletteTheme(
            size: CGFloat(fontSize),
            palette: palette,
            font: IDEEditorFonts.nsFont(familyName: fontName, size: CGFloat(fontSize))
        )
    }
}
