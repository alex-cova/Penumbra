import AppKit
import Penumbra

/// Example-app theme: quiet gutter, workbench-matched surfaces, DefaultTheme syntax colors.
final class IDEEditorTheme: Penumbra.Theme, @unchecked Sendable {
    static let shared = IDEEditorTheme()

    private let syntax = DefaultTheme()
    private var fontSize: CGFloat = 13

    private var codeFont: NSFont {
        NSFont(name: "Menlo", size: fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    var font: UIFont { codeFont }
    let textColor: UIColor = IDEAppearance.NSToken.foreground
    let gutterBackgroundColor: UIColor = IDEAppearance.NSToken.editor
    let gutterHairlineColor: UIColor = IDEAppearance.NSToken.border
    let lineNumberColor: UIColor = IDEAppearance.NSToken.muted
    var lineNumberFont: UIFont { codeFont }
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
    // Find bar: chrome-toned background (matches the tab/status bars), with a recessed,
    // editor-toned field so the input reads as a distinct surface rather than default AppKit
    // bezel chrome.
    let findBarBackgroundColor: UIColor = IDEAppearance.NSToken.sidebar
    let findBarHairlineColor: UIColor = IDEAppearance.NSToken.border
    let findBarFieldBackgroundColor: UIColor = IDEAppearance.NSToken.editor
    let findBarFieldBorderColor: UIColor = IDEAppearance.NSToken.border
    let findBarTextColor: UIColor = IDEAppearance.NSToken.foreground
    let findBarMutedTextColor: UIColor = IDEAppearance.NSToken.muted
    let findBarAccentColor: UIColor = IDEAppearance.NSToken.accent

    private init() {}

    func update(fontSize: Double) {
        self.fontSize = CGFloat(fontSize)
    }

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
