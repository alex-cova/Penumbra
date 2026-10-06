import AppKit
import TestTreeSitterLanguages
import XCTest
@testable import Penumbra

/// Smoke test for a batch edit (Replace All, Umbra's Tools ▸ Encode Base64) on a highlighted
/// document: the edit changes line lengths and the async highlight must not trip over them.
/// It passed before the fix too (the crash needs a highlight in flight at an unlucky moment), so
/// it does not prove the fix; it only keeps this path exercised with a tree-sitter language.
@MainActor
final class BatchReplaceSyntaxTests: XCTestCase {
    private var window: NSWindow!

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }

    func testBatchReplaceThatChangesLineLengthsReparsesAndHighlightsWithoutCrashing() {
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        textView.theme = DefaultTheme()
        window.contentView = textView
        let lines = (0 ..< 40).map { "const value\($0) = \"some string literal \($0)\"; // trailing comment" }
        let original = lines.joined(separator: "\n")
        textView.setState(TextViewState(text: original, theme: DefaultTheme(), language: TreeSitterLanguage(tree_sitter_javascript())))
        textView.layoutSubtreeIfNeeded()
        // No wait: the edit lands while the first highlight pass is still on its way back from
        // the background queue, which is when its tokens used to outlive the text they described.

        // Every literal becomes much longer, then much shorter than the line it sat in.
        let nsOriginal = original as NSString
        var replacements: [BatchReplaceSet.Replacement] = []
        var searchRange = NSRange(location: 0, length: nsOriginal.length)
        while true {
            let found = nsOriginal.range(of: "some string literal", range: searchRange)
            if found.location == NSNotFound { break }
            replacements.append(.init(range: found, text: String(repeating: "x", count: 120)))
            searchRange = NSRange(location: found.upperBound, length: nsOriginal.length - found.upperBound)
        }
        textView.replaceText(in: BatchReplaceSet(replacements: replacements))
        textView.layoutSubtreeIfNeeded()
        spin(0.5)
        XCTAssertTrue(textView.text.contains(String(repeating: "x", count: 120)))

        textView.undoManager?.undo()
        textView.layoutSubtreeIfNeeded()
        spin(0.5)
        XCTAssertEqual(textView.text, original)
    }
}
