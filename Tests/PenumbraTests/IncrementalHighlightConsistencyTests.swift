@preconcurrency import AppKit
import PenumbraLanguages
import EditorIntelligence
import PenumbraMarkdownLanguage
import SwiftIntelligence
import TreeSitterSwiftPenumbra
import XCTest
@testable import Penumbra

/// Differential tests for the editing fast paths (colour shift on a one-line edit, colour-only
/// refresh after a parse, row-scoped recolouring): after a sequence of keystrokes has settled, every
/// displayed line must look exactly like it does in a view freshly opened on the final text. A
/// mismatch means some incremental path left stale colours, fonts or line heights behind.
@MainActor
final class IncrementalHighlightConsistencyTests: XCTestCase {
    enum Edit {
        /// Types `text` one character at a time with the caret at `offset`.
        case type(String, at: Int)
        /// Deletes `length` characters ending at `offset` with repeated Backspace.
        case backspace(Int, at: Int)
        /// Replaces a range in one step (paste, completion, a formatter edit).
        case replace(NSRange, with: String)
        /// Types `text` with a caret at each offset.
        case typeAtCarets(String, at: [Int])
        case undo
        /// Scrolls to a fraction of the content height (0 = top, 1 = bottom).
        case scroll(CGFloat)
    }

    struct Language {
        let make: () -> TreeSitterLanguage
        let provider: TreeSitterLanguageProvider?
        var configuration: LanguageConfiguration = .generic
        /// Off for long-lined code: a wrapped line's height is only known once it has been laid out,
        /// so a live view and a fresh one disagree about the rows above the viewport.
        var wrapsLines = true

        static var markdown: Language { Language(make: { .markdown }, provider: MarkdownLanguageProvider()) }
        static var javaScript: Language { Language(make: { .javaScript }, provider: nil, configuration: .javaScript) }
        static var html: Language { Language(make: { .html }, provider: BundledLanguageProvider()) }
        static var http: Language { Language(make: { .http }, provider: BundledLanguageProvider()) }
        static var swift: Language { Language(make: { .swift }, provider: nil, configuration: .swift, wrapsLines: false) }
    }

    // MARK: - HTTP

    func testEditingAboveABodyWithTemplates() {
        let text = """
        GET https://example.com/a

        ###

        POST https://example.com/api
        Content-Type: application/json

        {
          "id": {{id}},
          "name": "x"
        }

        """
        assertConsistent(text, .http, edits: [.type("/more", at: offset(of: "/a\n", in: text) + 2)])
    }

    func testTypingATemplateInsideABody() {
        let text = """
        POST https://example.com/api
        Content-Type: application/json

        {
          "id": 1,
          "name": "x"
        }

        """
        assertConsistent(text, .http, edits: [.replace(NSRange(location: offset(of: "1,", in: text), length: 1), with: "{{id}}")])
    }

    // MARK: - Swift

    /// Moving a block of a SwiftUI view up a few dozen lines, as `IDEAgentSettingsView.swift` was
    /// edited: the committed text goes through the line removals and insertions that turn it into
    /// the current file, and every displayed line must match a fresh open of the result.
    func testMovingASwiftUIBlockLeavesNoStaleColours() {
        let before = AgentSettingsFixture.headSource
        let after = AgentSettingsFixture.source
        let edits = Self.lineEdits(from: before, to: after)
        XCTAssertFalse(edits.isEmpty)
        for fraction in [0, 0.15, 0.3, 0.6] as [CGFloat] {
            print("swift block move: scroll \(fraction)")
            assertConsistent(before, .swift, modes: [false], edits: edits + [.scroll(fraction)])
        }
    }

    /// Semantic tokens must paint the characters they name. The provider's offsets and the view's
    /// are different bookkeeping (UTF-8 bytes through `SourceTextMap` against UTF-16 line spans), so
    /// this checks the colours actually displayed, over the file with its non-ASCII characters.
    func testSemanticTokensPaintTheCharactersTheyName() async throws {
        let text = AgentSettingsFixture.source
        let (view, window) = makeView(text: text, language: .swift, policy: .eager)
        defer { window.orderOut(nil) }
        let provided = await SwiftSemanticTokenProvider().semanticHighlights(forSource: view.text)
        let tokens = try XCTUnwrap(provided)
        view.setSemanticHighlights(tokens.map {
            SyntaxHighlightRange(range: NSRange(location: $0.range.lowerBound, length: $0.range.count), highlightName: $0.highlightName)
        })
        settleFully(view)
        let ns = view.text as NSString
        var lineStarts = [0]
        for index in 0 ..< ns.length where ns.character(at: index) == 0x0A { lineStarts.append(index + 1) }
        var wrong: [String] = []
        var checked = 0
        var rowsSeen = Set<Int>()
        for fraction in stride(from: 0.0, through: 1.0, by: 0.1) {
            let maxY = max(view.contentSize.height - view.bounds.height, 0)
            view.contentOffset = CGPoint(x: 0, y: (maxY * CGFloat(fraction)).rounded())
            settleFully(view)
            for row in view.visibleRowsForTesting where rowsSeen.insert(row).inserted {
                guard row < lineStarts.count, let displayed = view.displayedLineForTesting(row: row) else { continue }
                let lineRange = NSRange(location: lineStarts[row], length: displayed.string.length)
                for token in tokens {
                    let range = NSRange(location: token.range.lowerBound, length: token.range.count)
                    guard let overlap = range.intersection(lineRange), overlap.length > 0,
                          let color = view.theme.textColor(for: token.highlightName) else { continue }
                    checked += 1
                    let local = overlap.location - lineRange.location
                    let painted = displayed.string.attribute(.foregroundColor, at: local, effectiveRange: nil) as? NSColor
                    if painted != color {
                        wrong.append("row \(row + 1): \(token.highlightName) '\(ns.substring(with: overlap))'")
                    }
                }
            }
        }
        XCTAssertGreaterThan(rowsSeen.count, 300, "the scroll did not cover the file")
        XCTAssertGreaterThan(checked, 20, "nothing was checked")
        XCTAssertTrue(wrong.isEmpty, "\(wrong.count) of \(checked) tokens not painted:\n" + wrong.prefix(25).joined(separator: "\n"))
    }

    /// Edits turning `old` into `new`, one `.replace` per contiguous run of removed or inserted
    /// lines, in an order where each range is valid for the text the earlier edits left.
    static func lineEdits(from old: String, to new: String) -> [Edit] {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        var lines = oldLines
        func location(ofLine index: Int) -> Int {
            lines[..<index].reduce(0) { $0 + ($1 as NSString).length + 1 }
        }
        var edits: [Edit] = []
        var removals: [(offset: Int, element: String)] = []
        var insertions: [(offset: Int, element: String)] = []
        for change in newLines.difference(from: oldLines) {
            switch change {
            case let .remove(offset, element, _): removals.append((offset, element))
            case let .insert(offset, element, _): insertions.append((offset, element))
            }
        }
        // Removals bottom to top, each run as one replace; then insertions top to bottom.
        var index = 0
        while index < removals.count {
            var end = index
            while end + 1 < removals.count, removals[end + 1].offset == removals[end].offset - 1 { end += 1 }
            let first = removals[end].offset, last = removals[index].offset
            let start = location(ofLine: first)
            let length = location(ofLine: last + 1) - start
            edits.append(.replace(NSRange(location: start, length: length), with: ""))
            lines.removeSubrange(first ... last)
            index = end + 1
        }
        index = 0
        while index < insertions.count {
            var end = index
            while end + 1 < insertions.count, insertions[end + 1].offset == insertions[end].offset + 1 { end += 1 }
            let run = insertions[index ... end]
            let text = run.map { $0.element + "\n" }.joined()
            edits.append(.replace(NSRange(location: location(ofLine: run.first!.offset), length: 0), with: text))
            lines.insert(contentsOf: run.map(\.element), at: run.first!.offset)
            index = end + 1
        }
        precondition(lines == newLines, "line edits do not reproduce the new text")
        return edits
    }

    // MARK: - Markdown

    func testDeletingHeadingMarkers() {
        let text = "- item\n\n## paymentHistory\n\n- userId\n"
        assertConsistent(text, .markdown, edits: [.backspace(3, at: offset(of: "paymentHistory", in: text))])
    }

    func testTypingHeadingMarkers() {
        let text = "- item\n\npaymentHistory\n\n- userId\n"
        assertConsistent(text, .markdown, edits: [.type("## ", at: offset(of: "paymentHistory", in: text))])
    }

    func testTypingASetextUnderlineTurnsThePreviousLineIntoAHeading() {
        let text = "intro\n\nTitle\n\nbody\n"
        let end = offset(of: "Title", in: text) + 5
        assertConsistent(text, .markdown, edits: [.type("\n===", at: end)])
    }

    func testDeletingASetextUnderline() {
        let text = "intro\n\nTitle\n===\n\nbody\n"
        let underlineEnd = offset(of: "===", in: text) + 3
        assertConsistent(text, .markdown, edits: [.backspace(4, at: underlineEnd)])
    }

    func testOpeningAFenceRecoloursTheLinesBelow() {
        let text = "intro\n\nlet x = 1\n// note\nconst y = \"s\"\n\nafter\n"
        assertConsistent(text, .markdown, edits: [.type("```js\n", at: offset(of: "let x", in: text))])
    }

    func testClosingAFence() {
        let text = "```js\nlet x = 1\nconst y = \"s\"\n\n# after\n\ntext\n"
        assertConsistent(text, .markdown, edits: [.type("```\n", at: offset(of: "\n# after", in: text) + 1)])
    }

    func testWrappingAParagraphInBold() {
        let text = "one two\nthree four\n\nnext\n"
        assertConsistent(text, .markdown, edits: [
            .type("**", at: offset(of: "three four", in: text) + 10),
            .type("**", at: 0)
        ])
    }

    func testTypingABlockQuoteMarker() {
        let text = "para one\ncontinues\n\nnext\n"
        assertConsistent(text, .markdown, edits: [.type("> ", at: 0)])
    }

    func testDeletingAHeadingLine() {
        let text = "a\n\n# Heading\n\nb\n\n## Other\n"
        let start = offset(of: "# Heading", in: text)
        assertConsistent(text, .markdown, edits: [.replace(NSRange(location: start, length: 11), with: "")])
    }

    // MARK: - JavaScript

    func testOpeningABlockComment() {
        let text = "const a = 1;\nfunction f(x) {\n  return \"s\" + x;\n}\nlet b = 2;\n"
        assertConsistent(text, .javaScript, edits: [.type("/*", at: 0)])
    }

    func testClosingABlockComment() {
        let text = "/* const a = 1;\nfunction f(x) {\n  return \"s\" + x;\n}\nlet b = 2;\n"
        assertConsistent(text, .javaScript, edits: [.type("*/", at: offset(of: "\nlet b", in: text))])
    }

    func testRemovingTheLineThatOpensABlockComment() {
        let text = "let z = 0;\n/*\nconst a = 1;\nfunction f(x) {}\n*/\nlet b = 2;\n"
        let start = offset(of: "/*\n", in: text)
        assertConsistent(text, .javaScript, edits: [.replace(NSRange(location: start, length: 3), with: "")])
    }

    func testOpeningATemplateLiteral() {
        let text = "const a = 1;\nconst b = x;\nfunction f() { return 2; }\n"
        assertConsistent(text, .javaScript, edits: [.type("`", at: offset(of: "x;", in: text))])
    }

    func testEnterInsideABlockComment() {
        let text = "/* one two */\nconst a = 1;\n"
        assertConsistent(text, .javaScript, edits: [.type("\n", at: offset(of: "two", in: text))])
    }

    // MARK: - Injections

    func testTypingAScriptTagInjectsJavaScript() {
        let text = "<p>hi</p>\nconst a = 1;\nfunction f() {}\n"
        assertConsistent(text, .html, edits: [
            .type("</script>", at: offset(of: "function f() {}", in: text) + 15),
            .type("<script>", at: offset(of: "const a", in: text))
        ])
    }

    // MARK: - One-step edits, undo, multiple carets

    func testSelectingAndDeletingHeadingMarkers() {
        let text = "- item\n\n## paymentHistory\n\n- userId\n"
        let start = offset(of: "## ", in: text)
        assertConsistent(text, .markdown, edits: [.replace(NSRange(location: start, length: 3), with: "")])
    }

    func testUndoingABlockComment() {
        let text = "const a = 1;\nfunction f(x) {\n  return \"s\" + x;\n}\nlet b = 2;\n"
        assertConsistent(text, .javaScript, edits: [.type("/*", at: 0), .undo, .undo])
    }

    func testUndoingHeadingMarkerDeletion() {
        let text = "intro\n\n## Heading\n\nbody\n"
        assertConsistent(text, .markdown, edits: [.backspace(3, at: offset(of: "Heading", in: text)), .undo, .undo, .undo])
    }

    /// Hunts the flake in `docs/HIGHLIGHT_FLAKE_HANDOFF.md`: reruns the settled-mode body for the
    /// multi-caret fixtures until one differs. Off unless `PENUMBRA_HIGHLIGHT_STRESS=<iterations>`.
    func testStressSettledMultiCaretHeadings() throws {
        let configured = ProcessInfo.processInfo.environment["PENUMBRA_HIGHLIGHT_STRESS"].flatMap(Int.init)
        try XCTSkipIf(configured == nil, "set PENUMBRA_HIGHLIGHT_STRESS=<iterations> to run")
        let raw = configured ?? 0
        continueAfterFailure = false
        let multi = "one\n\ntwo\n\nthree\n"
        let undo = "intro\n\n## Heading\n\nbody\n"
        for iteration in 0 ..< raw {
            assertConsistent(multi, .markdown, modes: [true], edits: [
                .typeAtCarets("## ", at: [0, offset(of: "two", in: multi), offset(of: "three", in: multi)])
            ])
            assertConsistent(undo, .markdown, modes: [true], edits: [
                .backspace(3, at: offset(of: "Heading", in: undo)), .undo, .undo, .undo
            ])
            if iteration % 25 == 0 { print("stress iteration \(iteration)") }
        }
    }

    func testTypingHeadingMarkersAtSeveralCarets() {
        let text = "one\n\ntwo\n\nthree\n"
        assertConsistent(text, .markdown, edits: [
            .typeAtCarets("## ", at: [0, offset(of: "two", in: text), offset(of: "three", in: text)])
        ])
    }

    // MARK: - Lines off screen during the edit

    private var longJavaScript: String {
        (0 ..< 400).map { "const value\($0) = \"text \($0)\"; // note \($0)" }.joined(separator: "\n") + "\n"
    }

    private var longMarkdown: String {
        (0 ..< 200).map { "## Section \($0)\n\nParagraph \($0) with **bold** and `code`." }.joined(separator: "\n\n") + "\n"
    }

    func testOpeningABlockCommentThenScrollingDown() {
        assertConsistent(longJavaScript, .javaScript, edits: [.type("/*", at: 0), .scroll(0.5)])
    }

    func testOpeningABlockCommentOnItsOwnLineThenScrollingDown() {
        assertConsistent(longJavaScript, .javaScript, edits: [.type("/*\n", at: 0), .scroll(0.3)])
    }

    func testClosingABlockCommentThenScrollingDown() {
        assertConsistent("/*\n" + longJavaScript, .javaScript, edits: [.type("*/", at: 2), .scroll(0.5)])
    }

    func testEditingAboveTheViewportWhileScrolled() {
        let text = longJavaScript
        assertConsistent(text, .javaScript, edits: [
            .scroll(0.2),
            .replace(NSRange(location: 0, length: 0), with: "/*"),
            .scroll(0.25),
            .scroll(0)
        ])
    }

    func testOpeningAFenceAtTheTopOfALongDocumentThenScrollingDown() {
        assertConsistent(longMarkdown, .markdown, edits: [.type("```\n", at: 0), .scroll(0.4)])
    }

    func testViewportPolicyOpeningABlockCommentThenScrollingDown() {
        let original = TreeSitterPerformanceConstants.maxSyncContentLength
        TreeSitterPerformanceConstants.maxSyncContentLength = 2_000
        defer { TreeSitterPerformanceConstants.maxSyncContentLength = original }
        assertConsistent(longJavaScript, .javaScript, policy: .viewport, edits: [.type("/*", at: 0), .scroll(0.5)])
    }

    func testViewportPolicyTypingHeadingMarkersBelowTheFold() {
        let original = TreeSitterPerformanceConstants.maxSyncContentLength
        TreeSitterPerformanceConstants.maxSyncContentLength = 2_000
        defer { TreeSitterPerformanceConstants.maxSyncContentLength = original }
        let text = longMarkdown
        let target = offset(of: "Paragraph 120", in: text)
        assertConsistent(text, .markdown, policy: .viewport, edits: [.scroll(0.6), .type("# ", at: target)])
    }

    // MARK: - Synchronous keystroke parse (`PenumbraSyncKeystrokeParse`)

    private func withSyncKeystrokeParse(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: PenumbraSyncKeystrokeParse.defaultsKey)
        defaults.set(true, forKey: PenumbraSyncKeystrokeParse.defaultsKey)
        defer { defaults.set(previous, forKey: PenumbraSyncKeystrokeParse.defaultsKey) }
        body()
    }

    func testSyncParseOpeningABlockCommentAtTheStart() {
        withSyncKeystrokeParse {
            let text = "const a = 1;\nfunction f(x) {\n  return \"s\" + x;\n}\nlet b = 2;\n"
            assertConsistent(text, .javaScript, edits: [.type("/*", at: 0)])
        }
    }

    func testSyncParseTypingHeadingMarkersAtTheStart() {
        withSyncKeystrokeParse {
            assertConsistent("Title\n\nbody\n", .markdown, edits: [.type("# ", at: 0)])
        }
    }

    func testSyncParseClosingABlockComment() {
        withSyncKeystrokeParse {
            let text = "/* const a = 1;\nfunction f(x) {\n  return \"s\" + x;\n}\nlet b = 2;\n"
            assertConsistent(text, .javaScript, edits: [.type("*/", at: offset(of: "\nlet b", in: text))])
        }
    }

    func testSyncParseOpeningAFence() {
        withSyncKeystrokeParse {
            let text = "intro\n\nlet x = 1\n// note\n\nafter\n"
            assertConsistent(text, .markdown, edits: [.type("```js\n", at: offset(of: "let x", in: text))])
        }
    }

    // MARK: - Harness

    private func offset(of needle: String, in text: String) -> Int {
        let range = (text as NSString).range(of: needle)
        precondition(range.location != NSNotFound, "\(needle) not in fixture")
        return range.location
    }

    private func assertConsistent(
        _ initialText: String,
        _ language: Language,
        policy: SyntaxParsePolicy = .eager,
        modes: [Bool] = [true, false],
        edits: [Edit],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for settleBetweenKeystrokes in modes {
            let (live, liveWindow) = makeView(text: initialText, language: language, policy: policy)
            for edit in edits {
                apply(edit, to: live, settle: settleBetweenKeystrokes)
            }
            settleFully(live)
            let finalText = live.text
            let (fresh, freshWindow) = makeView(text: finalText, language: language, policy: policy)
            fresh.contentOffset = live.contentOffset
            settleFully(fresh)
            let mode = settleBetweenKeystrokes ? "settled" : "burst"
            var diffs = differences(live: live, fresh: fresh)
            diffs += minimapDifferences(live: live, fresh: fresh)
            if live.foldLineRangesForTesting != fresh.foldLineRangesForTesting {
                diffs.append("folds \(live.foldLineRangesForTesting) vs \(fresh.foldLineRangesForTesting)")
            }
            if live.methodSeparatorRowsForTesting != fresh.methodSeparatorRowsForTesting {
                diffs.append("method separators \(live.methodSeparatorRowsForTesting) vs \(fresh.methodSeparatorRowsForTesting)")
            }
            XCTAssertTrue(diffs.isEmpty, "[\(mode)] incremental rendering differs from a fresh open:\n" + diffs.joined(separator: "\n"),
                          file: file, line: line)
            liveWindow.orderOut(nil)
            freshWindow.orderOut(nil)
        }
    }

    private func apply(_ edit: Edit, to textView: TextView, settle shouldSettle: Bool) {
        switch edit {
        case let .type(text, offset):
            textView.selectedRange = NSRange(location: offset, length: 0)
            for character in text {
                textView.insertText(String(character))
                if shouldSettle { settle(textView) }
            }
        case let .backspace(count, offset):
            textView.selectedRange = NSRange(location: offset, length: 0)
            for _ in 0 ..< count {
                textView.deleteBackward()
                if shouldSettle { settle(textView) }
            }
        case let .replace(range, text):
            textView.replace(range, withText: text)
            if shouldSettle { settle(textView) }
        case let .typeAtCarets(text, offsets):
            textView.selectedRanges = offsets.map { NSRange(location: $0, length: 0) }
            for character in text {
                textView.insertText(String(character))
                if shouldSettle { settle(textView) }
            }
        case .undo:
            textView.undoManager?.undo()
            if shouldSettle { settle(textView) }
        case let .scroll(fraction):
            let maxY = max(textView.contentSize.height - textView.bounds.height, 0)
            textView.contentOffset = CGPoint(x: 0, y: (maxY * fraction).rounded())
            settle(textView)
        }
    }

    private func makeView(text: String, language: Language, policy: SyntaxParsePolicy) -> (TextView, NSWindow) {
        let frame = CGRect(x: 0, y: 0, width: 700, height: 500)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let textView = TextView(frame: frame)
        window.contentView = textView
        textView.theme = PaletteTheme(
            size: 13,
            palette: ThemeCatalog.palette(id: ThemeCatalog.defaultDarkID, fallbackDark: true),
            postscriptName: "Menlo-Regular"
        )
        textView.isLineWrappingEnabled = language.wrapsLines
        textView.showMinimap = true
        textView.isLineFoldingEnabled = true
        textView.showMethodSeparators = true
        textView.languageConfigurationOverride = language.configuration
        textView.minimapViewForTesting.debugRecordsDrawnRows = true
        textView.setState(TextViewState(
            text: text, language: language.make(), languageProvider: language.provider, parsePolicy: policy
        ))
        settle(textView)
        return (textView, window)
    }

    /// Runs the loop until the parse and the async line highlights it triggers have landed.
    private func settle(_ textView: TextView) {
        let deadline = Date().addingTimeInterval(3)
        while !textView.isSyntaxTreeReady, Date() < deadline {
            textView.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        for _ in 0 ..< 8 {
            textView.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// Also waits out the fold scan's edit debounce.
    private func settleFully(_ textView: TextView) {
        settle(textView)
        for _ in 0 ..< 30 {
            textView.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func differences(live: TextView, fresh: TextView) -> [String] {
        var diffs: [String] = []
        let liveRows = live.visibleRowsForTesting
        let freshRows = fresh.visibleRowsForTesting
        if liveRows != freshRows {
            diffs.append("visible rows \(liveRows.first ?? -1)...\(liveRows.last ?? -1) vs \(freshRows.first ?? -1)...\(freshRows.last ?? -1)")
        }
        if liveRows.isEmpty {
            diffs.append("no visible rows to compare")
        }
        for row in Set(liveRows).intersection(freshRows).sorted() {
            guard let liveLine = live.displayedLineForTesting(row: row),
                  let freshLine = fresh.displayedLineForTesting(row: row) else {
                continue
            }
            let text = liveLine.string.string.trimmingCharacters(in: .newlines)
            if liveLine.string.string != freshLine.string.string {
                diffs.append("row \(row): text \(liveLine.string.string.debugDescription) vs \(freshLine.string.string.debugDescription)")
                continue
            }
            if abs(liveLine.height - freshLine.height) > 0.5 {
                diffs.append("row \(row) \(text.debugDescription): height \(liveLine.height) vs \(freshLine.height)")
            }
            for index in 0 ..< liveLine.string.length {
                let a = describe(liveLine.string.attributes(at: index, effectiveRange: nil))
                let b = describe(freshLine.string.attributes(at: index, effectiveRange: nil))
                if a != b {
                    let character = (liveLine.string.string as NSString).substring(with: NSRange(location: index, length: 1))
                    diffs.append("row \(row) \(text.debugDescription) col \(index) \(character.debugDescription): \(a) vs \(b)")
                    break
                }
            }
        }
        return diffs
    }

    private func minimapDifferences(live: TextView, fresh: TextView) -> [String] {
        func draw(_ textView: TextView) -> [Int: String] {
            let minimap = textView.minimapViewForTesting
            minimap.needsDisplay = true
            if let bitmap = minimap.bitmapImageRepForCachingDisplay(in: minimap.bounds) {
                minimap.cacheDisplay(in: minimap.bounds, to: bitmap)
            }
            return minimap.debugDrawnRows
        }
        let liveRows = draw(live)
        let freshRows = draw(fresh)
        if liveRows.isEmpty {
            return ["minimap drew no rows"]
        }
        var diffs: [String] = []
        for row in Set(liveRows.keys).intersection(freshRows.keys).sorted() where liveRows[row] != freshRows[row] {
            diffs.append("minimap row \(row): \(liveRows[row]!) vs \(freshRows[row]!)")
            if diffs.count > 8 { break }
        }
        return diffs
    }

    private func describe(_ attributes: [NSAttributedString.Key: Any]) -> String {
        var parts: [String] = []
        if let font = attributes[.font] as? NSFont {
            parts.append("\(font.fontName) \(font.pointSize)")
        }
        if let color = (attributes[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB) {
            parts.append(String(format: "#%02X%02X%02X", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255)))
        }
        if attributes[.shadow] != nil { parts.append("shadow") }
        if let kern = attributes[.kern] as? NSNumber, kern.doubleValue != 0 { parts.append("kern \(kern)") }
        return parts.joined(separator: " ")
    }
}
