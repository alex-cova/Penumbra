import Foundation

/// The set of syntax themes shipped with Penumbra. `hextech-light` / `hextech-dark` are the
/// default palettes used by Hextech; the rest are ported from Runestone's original example themes
/// or well-known published schemes (Solarized, Dracula, Nord, GitHub, Monokai).
public enum ThemeCatalog {
    public static let defaultLightID = "hextech-light"
    public static let defaultDarkID = "hextech-dark"

    public static let all: [ThemePalette] = [
        hextechLight, hextechDark,
        tomorrow, tomorrowNight, oneDark,
        solarizedLight, solarizedDark,
        dracula, nord,
        githubLight, githubDark,
        monokai
    ]

    /// Looks up a palette by ID, falling back to the default palette for `fallbackDark`
    /// when the ID is unknown (e.g. a theme removed in a later build).
    public static func palette(id: String, fallbackDark: Bool) -> ThemePalette {
        all.first { $0.id == id } ?? (fallbackDark ? hextechDark : hextechLight)
    }

    /// All palettes, with those suited to `isDark` listed first. Every palette is still
    /// included for either appearance — nothing is unreachable.
    public static func palettes(preferring isDark: Bool) -> [ThemePalette] {
        all.filter { $0.isDark == isDark } + all.filter { $0.isDark != isDark }
    }

    // MARK: - Hextech (default)

    fileprivate static let hextechLight = ThemePalette(
        id: defaultLightID, name: "Hextech", isDark: false,
        background: 0xFFFFFF, text: 0x1A1A1A,
        gutterBackground: 0xFFFFFF, gutterHairline: 0xE0E0E0, lineNumber: 0x8E8E93,
        selectedLineBackground: 0xF2F2F7, selectedLinesLineNumber: 0x3A3A3C,
        selectedLinesGutterBackground: 0xFFFFFF, invisibleCharacters: 0xC7C7CC,
        pageGuideHairline: 0xD1D1D6, pageGuideBackground: 0xFAFAFA,
        markedTextBackground: 0xFFE08A,
        comment: 0x6B6B6B, constant: 0x1C1C9C, type: 0x267F99, function: 0x795E26,
        keyword: 0x9B229C, number: 0x1C00CF, property: 0x0451A5, string: 0xA31515,
        variableBuiltin: 0x0070C1, punctuation: 0x383A42
    )

    fileprivate static let hextechDark = ThemePalette(
        id: defaultDarkID, name: "Hextech Dark", isDark: true,
        background: 0x1E1E1E, text: 0xE6E6E6,
        gutterBackground: 0x1E1E1E, gutterHairline: 0x2C2C2C, lineNumber: 0x8E8E93,
        selectedLineBackground: 0x2C2C2E, selectedLinesLineNumber: 0xEBEBF5,
        selectedLinesGutterBackground: 0x1E1E1E, invisibleCharacters: 0x48484A,
        pageGuideHairline: 0x3A3A3C, pageGuideBackground: 0x1C1C1E,
        markedTextBackground: 0x5C4B00,
        comment: 0x6A9955, constant: 0xD0A8FF, type: 0x4EC9B0, function: 0xDCDCAA,
        keyword: 0xFC6C85, number: 0xB5D4A8, property: 0x9CDCFE, string: 0xFC9A5D,
        variableBuiltin: 0x569CD6, punctuation: 0xD4D4D4
    )

    // MARK: - Ported from Runestone's Example/Themes

    fileprivate static let tomorrow = make(
        id: "tomorrow", name: "Tomorrow", isDark: false,
        background: 0xFFFFFF, text: 0x4D4D4C, comment: 0x8E908C, currentLine: 0xEFEFEF,
        keyword: 0x8959A8, string: 0x718C00, number: 0xF5871F, function: 0x4271AE,
        property: 0x3E999F, type: 0xEAB700, constant: 0xF5871F, variableBuiltin: 0xC82829
    )

    fileprivate static let tomorrowNight = make(
        id: "tomorrow-night", name: "Tomorrow Night", isDark: true,
        background: 0x1D1F21, text: 0xC5C8C6, comment: 0x969896, currentLine: 0x282A2E,
        keyword: 0xB294BB, string: 0xB5BD68, number: 0xDE935F, function: 0x81A2BE,
        property: 0x8ABEB7, type: 0xF0C674, constant: 0xDE935F, variableBuiltin: 0xCC6666
    )

    fileprivate static let oneDark = make(
        id: "one-dark", name: "One Dark", isDark: true,
        background: 0x282C34, text: 0xABB2BF, comment: 0x787D87, currentLine: 0x363941,
        keyword: 0xC678DD, string: 0x98C379, number: 0xE5C07B, function: 0x61AFEF,
        property: 0x56B6C2, type: 0x56B6C2, constant: 0xE5C07B, variableBuiltin: 0xE06C75
    )

    // MARK: - Well-known classics

    fileprivate static let solarizedLight = make(
        id: "solarized-light", name: "Solarized Light", isDark: false,
        background: 0xFDF6E3, text: 0x657B83, comment: 0x93A1A1, currentLine: 0xEEE8D5,
        keyword: 0x6C71C4, string: 0x2AA198, number: 0xD33682, function: 0x268BD2,
        property: 0x2AA198, type: 0xB58900, constant: 0xCB4B16, variableBuiltin: 0xDC322F,
        selectedLinesLineNumber: 0x586E75
    )

    fileprivate static let solarizedDark = make(
        id: "solarized-dark", name: "Solarized Dark", isDark: true,
        background: 0x002B36, text: 0x839496, comment: 0x586E75, currentLine: 0x073642,
        keyword: 0x6C71C4, string: 0x2AA198, number: 0xD33682, function: 0x268BD2,
        property: 0x2AA198, type: 0xB58900, constant: 0xCB4B16, variableBuiltin: 0xDC322F,
        selectedLinesLineNumber: 0x93A1A1
    )

    fileprivate static let dracula = make(
        id: "dracula", name: "Dracula", isDark: true,
        background: 0x282A36, text: 0xF8F8F2, comment: 0x6272A4, currentLine: 0x44475A,
        keyword: 0xFF79C6, string: 0xF1FA8C, number: 0xBD93F9, function: 0x50FA7B,
        property: 0x8BE9FD, type: 0xFFB86C, constant: 0xBD93F9, variableBuiltin: 0xFF5555
    )

    fileprivate static let nord = make(
        id: "nord", name: "Nord", isDark: true,
        background: 0x2E3440, text: 0xD8DEE9, comment: 0x4C566A, currentLine: 0x3B4252,
        keyword: 0x81A1C1, string: 0xA3BE8C, number: 0xB48EAD, function: 0x88C0D0,
        property: 0x8FBCBB, type: 0xEBCB8B, constant: 0xD08770, variableBuiltin: 0xBF616A,
        selectedLinesLineNumber: 0xECEFF4
    )

    fileprivate static let githubLight = make(
        id: "github-light", name: "GitHub Light", isDark: false,
        background: 0xFFFFFF, text: 0x24292E, comment: 0x6A737D, currentLine: 0xF6F8FA,
        keyword: 0xD73A49, string: 0x032F62, number: 0x005CC5, function: 0x6F42C1,
        property: 0x005CC5, type: 0x22863A, constant: 0xE36209, variableBuiltin: 0xD73A49
    )

    fileprivate static let githubDark = make(
        id: "github-dark", name: "GitHub Dark", isDark: true,
        background: 0x24292E, text: 0xE1E4E8, comment: 0x6A737D, currentLine: 0x2F363D,
        keyword: 0xF97583, string: 0x9ECBFF, number: 0x79B8FF, function: 0xB392F0,
        property: 0x79B8FF, type: 0x85E89D, constant: 0xFFAB70, variableBuiltin: 0xF97583
    )

    fileprivate static let monokai = make(
        id: "monokai", name: "Monokai", isDark: true,
        background: 0x272822, text: 0xF8F8F2, comment: 0x75715E, currentLine: 0x3E3D32,
        keyword: 0xF92672, string: 0xE6DB74, number: 0xAE81FF, function: 0xA6E22E,
        property: 0x66D9EF, type: 0x66D9EF, constant: 0xAE81FF, variableBuiltin: 0xFD971F
    )

    private static func make(
        id: String,
        name: String,
        isDark: Bool,
        background: UInt32,
        text: UInt32,
        comment: UInt32,
        currentLine: UInt32,
        keyword: UInt32,
        string: UInt32,
        number: UInt32,
        function: UInt32,
        property: UInt32,
        type: UInt32,
        constant: UInt32,
        variableBuiltin: UInt32,
        selectedLinesLineNumber: UInt32? = nil,
        punctuation: UInt32? = nil
    ) -> ThemePalette {
        ThemePalette(
            id: id, name: name, isDark: isDark,
            background: background, text: text,
            gutterBackground: background,
            gutterHairline: comment,
            lineNumber: comment,
            selectedLineBackground: currentLine,
            selectedLinesLineNumber: selectedLinesLineNumber ?? text,
            selectedLinesGutterBackground: background,
            invisibleCharacters: comment,
            pageGuideHairline: comment,
            pageGuideBackground: currentLine,
            markedTextBackground: isDark ? 0x5C4B00 : 0xFFE08A,
            comment: comment, constant: constant, type: type, function: function,
            keyword: keyword, number: number, property: property, string: string,
            variableBuiltin: variableBuiltin, punctuation: punctuation ?? comment
        )
    }
}
