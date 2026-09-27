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
        return nil
    }
}
