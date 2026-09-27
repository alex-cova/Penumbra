import Penumbra
import AppKit

class TomorrowTheme: Theme {
    let font: NSFont = .monospacedSystemFont(ofSize: 14, weight: .regular)
    let textColor: NSColor = .tomorrow.foreground

    let gutterBackgroundColor: NSColor = .tomorrow.background
    let gutterHairlineColor: NSColor = .tomorrow.background

    let lineNumberColor: NSColor = .tomorrow.comment
    let lineNumberFont: NSFont = .monospacedSystemFont(ofSize: 14, weight: .regular)

    let selectedLineBackgroundColor: NSColor = .tomorrow.currentLine
    let selectedLinesLineNumberColor: NSColor = .tomorrow.foreground
    let selectedLinesGutterBackgroundColor: NSColor = .tomorrow.background

    let invisibleCharactersColor: NSColor = .tomorrow.comment

    let pageGuideHairlineColor: NSColor = .tomorrow.foreground.withAlphaComponent(0.1)
    let pageGuideBackgroundColor: NSColor = .tomorrow.foreground.withAlphaComponent(0.2)

    let markedTextBackgroundColor: NSColor = .tomorrow.foreground.withAlphaComponent(0.2)

    func textColor(for highlightName: String) -> NSColor? {
        guard let highlightName = HighlightName(highlightName) else {
            return nil
        }
        switch highlightName {
        case .comment:
            return .tomorrow.comment
        case .constructor:
            return .tomorrow.yellow
        case .function:
            return .tomorrow.blue
        case .keyword, .type:
            return .tomorrow.purple
        case .number, .constantBuiltin, .constantCharacter:
            return .tomorrow.orange
        case .property:
            return .tomorrow.aqua
        case .string:
            return .tomorrow.green
        case .variableBuiltin:
            return .tomorrow.red
        case .operator, .punctuation:
            return .tomorrow.foreground.withAlphaComponent(0.75)
        case .variable:
            return nil
        }
    }

    func fontTraits(for highlightName: String) -> FontTraits {
        guard let highlightName = HighlightName(highlightName) else {
            return []
        }
        if highlightName == .keyword {
            return .bold
        } else {
            return []
        }
    }
}
