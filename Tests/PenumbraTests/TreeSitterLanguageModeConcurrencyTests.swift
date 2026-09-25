import Foundation
@testable import Penumbra
import PenumbraLanguages
import XCTest

/// Node lookups on the main thread while a background parse replaces the layer's tree. They used
/// to read `TreeSitterLanguageLayer.tree` outside `parseLock` (and ignored an in-flight parse).
/// The race rarely crashes in a normal run; run under TSan to see it
/// (`swift test --sanitize=thread --filter TreeSitterLanguageModeConcurrencyTests`).
final class TreeSitterLanguageModeConcurrencyTests: XCTestCase {
    @MainActor
    func testNodeLookupsDuringBackgroundParses() {
        var lines = ["package demo;", ""]
        for index in 0 ..< 400 {
            lines.append("class C\(index) {")
            lines.append("    int f(int x) {")
            lines.append("        return x + \(index);")
            lines.append("    }")
            lines.append("}")
        }
        let source = lines.joined(separator: "\n")
        let stringView = StringView(string: source)
        let lineManager = LineManager(stringView: stringView)
        lineManager.rebuild()
        let mode = TreeSitterInternalLanguageMode(
            language: TreeSitterLanguage.java.internalLanguage,
            languageProvider: nil,
            stringView: stringView,
            lineManager: lineManager
        )
        // Background parse: a main-thread parse has a time budget that sanitizer builds exceed.
        var initialParseFinished = false
        mode.parse { _ in initialParseFinished = true }
        let initialDeadline = Date().addingTimeInterval(30)
        while !initialParseFinished, Date() < initialDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertNotNil(mode.syntaxNode(at: LinePosition(row: 4, column: 8)))

        // Each parse cancels queued ones (whose completions never run); wait for the last.
        var lastParseFinished = false
        let rounds = 60
        for round in 0 ..< rounds {
            let isLast = round == rounds - 1
            mode.parse { _ in
                if isLast {
                    lastParseFinished = true
                }
            }
            for probe in 0 ..< 40 {
                let position = LinePosition(row: 2 + (round * 40 + probe) % (lines.count - 2), column: 4)
                _ = mode.syntaxNode(at: position)
                _ = mode.treeSitterNode(at: position)
                _ = mode.rootSyntaxNode?.childCount
                _ = mode.strategyForInsertingLineBreak(from: position, to: position, using: .space(length: 4))
                _ = mode.canHighlight
            }
        }
        let deadline = Date().addingTimeInterval(30)
        while !lastParseFinished, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(lastParseFinished)
        XCTAssertEqual(mode.syntaxNode(at: LinePosition(row: 4, column: 8))?.type, mode.treeSitterNode(at: LinePosition(row: 4, column: 8))?.type)
    }
}
