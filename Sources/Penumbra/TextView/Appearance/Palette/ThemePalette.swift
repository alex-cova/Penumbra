import AppKit
import Foundation

/// A complete color set for ``PaletteTheme``: editor chrome (gutter, line numbers,
/// selection, page guide) plus syntax roles. Colors are raw `UInt32` sRGB hex values so a
/// palette stays plain `Sendable` value data with no AppKit dependency, and can be rendered
/// by both the real Penumbra theme and a pure-SwiftUI settings preview from the same source
/// of truth.
public struct ThemePalette: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// Which appearance this palette is designed for. Used only to sort/group theme pickers —
    /// every palette remains selectable for either appearance.
    public let isDark: Bool

    // Chrome
    public let background: UInt32
    public let text: UInt32
    public let gutterBackground: UInt32
    public let gutterHairline: UInt32
    public let lineNumber: UInt32
    public let selectedLineBackground: UInt32
    public let selectedLinesLineNumber: UInt32
    public let selectedLinesGutterBackground: UInt32
    public let invisibleCharacters: UInt32
    public let pageGuideHairline: UInt32
    public let pageGuideBackground: UInt32
    public let markedTextBackground: UInt32

    // Syntax roles — matches the buckets ``PaletteTheme`` switches on.
    public let comment: UInt32
    public let constant: UInt32
    public let type: UInt32
    public let function: UInt32
    public let keyword: UInt32
    public let number: UInt32
    public let property: UInt32
    public let string: UInt32
    public let variableBuiltin: UInt32
    public let punctuation: UInt32

    public init(
        id: String,
        name: String,
        isDark: Bool,
        background: UInt32,
        text: UInt32,
        gutterBackground: UInt32,
        gutterHairline: UInt32,
        lineNumber: UInt32,
        selectedLineBackground: UInt32,
        selectedLinesLineNumber: UInt32,
        selectedLinesGutterBackground: UInt32,
        invisibleCharacters: UInt32,
        pageGuideHairline: UInt32,
        pageGuideBackground: UInt32,
        markedTextBackground: UInt32,
        comment: UInt32,
        constant: UInt32,
        type: UInt32,
        function: UInt32,
        keyword: UInt32,
        number: UInt32,
        property: UInt32,
        string: UInt32,
        variableBuiltin: UInt32,
        punctuation: UInt32
    ) {
        self.id = id
        self.name = name
        self.isDark = isDark
        self.background = background
        self.text = text
        self.gutterBackground = gutterBackground
        self.gutterHairline = gutterHairline
        self.lineNumber = lineNumber
        self.selectedLineBackground = selectedLineBackground
        self.selectedLinesLineNumber = selectedLinesLineNumber
        self.selectedLinesGutterBackground = selectedLinesGutterBackground
        self.invisibleCharacters = invisibleCharacters
        self.pageGuideHairline = pageGuideHairline
        self.pageGuideBackground = pageGuideBackground
        self.markedTextBackground = markedTextBackground
        self.comment = comment
        self.constant = constant
        self.type = type
        self.function = function
        self.keyword = keyword
        self.number = number
        self.property = property
        self.string = string
        self.variableBuiltin = variableBuiltin
        self.punctuation = punctuation
    }

    /// Text-selection highlight shared by ``PaletteTheme/selectionColor`` and live
    /// `TextView.selectionHighlightColor` when an app applies chrome in place.
    public static func selectionHighlightColor(isDark: Bool) -> NSColor {
        _ = isDark
        return NSColor(rgb: 0x3B82F6, alpha: 125 / 255)
    }
}
