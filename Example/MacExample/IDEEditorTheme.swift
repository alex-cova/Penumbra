import AppKit
import Runestone

/// Example-app theme: quiet gutter, workbench-matched surfaces, DefaultTheme syntax colors.
final class IDEEditorTheme: Runestone.Theme, @unchecked Sendable {
    static let shared = IDEEditorTheme()

    private let syntax = DefaultTheme()
    nonisolated(unsafe) private static let codeFont = NSFont(name: "Menlo", size: 13)
        ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    let font: UIFont = IDEEditorTheme.codeFont
    let textColor: UIColor = IDEAppearance.NSToken.foreground
    let gutterBackgroundColor: UIColor = IDEAppearance.NSToken.editor
    let gutterHairlineColor: UIColor = IDEAppearance.NSToken.border
    let lineNumberColor: UIColor = IDEAppearance.NSToken.muted
    let lineNumberFont: UIFont = IDEEditorTheme.codeFont
    let selectedLineBackgroundColor: UIColor = IDEAppearance.NSToken.selection
    let selectedLinesLineNumberColor: UIColor = IDEAppearance.NSToken.foreground
    let selectedLinesGutterBackgroundColor: UIColor = IDEAppearance.NSToken.editor
    let invisibleCharactersColor: UIColor = IDEAppearance.NSToken.muted
    let pageGuideHairlineColor: UIColor = IDEAppearance.NSToken.border
    let pageGuideBackgroundColor: UIColor = IDEAppearance.NSToken.editor
    let markedTextBackgroundColor: UIColor = IDEAppearance.NSToken.selection
    let selectionColor: UIColor = IDEAppearance.NSToken.accent.withAlphaComponent(0.35)
    let methodSeparatorColor: UIColor = IDEAppearance.NSToken.border
    let occurrenceHighlightColor: UIColor = IDEAppearance.NSToken.accent.withAlphaComponent(0.18)

    private init() {}

    func textColor(for highlightName: String) -> UIColor? {
        syntax.textColor(for: highlightName)
    }

    func fontTraits(for highlightName: String) -> FontTraits {
        syntax.fontTraits(for: highlightName)
    }

    func highlightedRange(
        forFoundTextRange foundTextRange: NSRange,
        ofStyle style: UITextSearchFoundTextStyle
    ) -> HighlightedRange? {
        syntax.highlightedRange(forFoundTextRange: foundTextRange, ofStyle: style)
    }
}
