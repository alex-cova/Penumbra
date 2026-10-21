import Foundation

/// Next / Previous Method (⌃↓ / ⌃↑ in the IntelliJ keymap): the name of the nearest function
/// declaration after or before the caret, read from the syntax tree.
///
/// Keypress work, not editing work: it scans a window of rows around the caret that grows by a
/// factor of four until it finds a method or covers the rest of the document, so a method a few
/// lines away costs a few lines of tree walk, never the whole file.
enum MethodNavigator {
    static let initialRowSpan = 400

    /// UTF-16 offset of the method name after (or before) `location`, or nil when there is none.
    static func target(
        from location: Int,
        row: Int,
        lineCount: Int,
        forward: Bool,
        root: TreeSitterNode,
        configuration: LanguageConfiguration
    ) -> Int? {
        guard lineCount > 0 else { return nil }
        var span = initialRowSpan
        while true {
            let lower = forward ? row : max(0, row - span)
            let upper = forward ? min(lineCount - 1, row + span) : row
            let starts = DeclarationScanner.scan(
                root: root, configuration: configuration, text: nil, rowWindow: lower ... max(lower, upper)
            )
            .filter { $0.kind == .function }
            .map(\.name_span.startUTF16)
            if let found = nearest(in: starts, to: location, forward: forward) {
                return found
            }
            if forward ? upper >= lineCount - 1 : lower == 0 {
                return nil
            }
            span *= 4
        }
    }

    /// The smallest start after `location` (forward) or the largest one before it.
    static func nearest(in starts: [Int], to location: Int, forward: Bool) -> Int? {
        forward ? starts.filter { $0 > location }.min() : starts.filter { $0 < location }.max()
    }
}

extension TextInputView {
    /// Moves every selection to a collapsed caret on the next or previous method name. Returns
    /// whether it moved; false without a syntax tree or a language configuration.
    @discardableResult
    func goToMethod(forward: Bool) -> Bool {
        guard let mode = languageMode as? TreeSitterInternalLanguageMode,
              let configuration = languageConfiguration,
              let root = mode.rootSyntaxNode,
              let selection else {
            return false
        }
        // From the end of a selection going forward and its start going back, as for any caret move.
        let origin = forward ? selection.upperBound : selection.location
        guard let row = lineManager.row(containingCharacterAt: origin),
              let target = MethodNavigator.target(
                from: origin, row: row, lineCount: lineManager.lineCount,
                forward: forward, root: root, configuration: configuration
              ) else {
            return false
        }
        self.selection = NSRange(location: target, length: 0)
        return true
    }
}
