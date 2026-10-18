import EditorIntelligence
import XCTest
@testable import JavaIntelligence

final class JavaIntentionTests: XCTestCase {
    private let index = JavaIndex()

    func testOptionsRoundTripKeepsDefaultsAndDeviations() {
        let restored = JavaIntentionOptions.restored(disabledIDs: nil, showsBulb: nil, showsPreview: nil)
        XCTAssertEqual(restored, .standard)
        XCTAssertTrue(restored.showsBulb)
        XCTAssertTrue(restored.showsPreview)
        XCTAssertTrue(JavaIntention.all.allSatisfy(restored.isEnabled))

        let turned = JavaIntentionOptions.restored(
            disabledIDs: [JavaIntention.invertIf.id], showsBulb: false, showsPreview: nil
        )
        XCTAssertEqual(turned.disabledIDs, [JavaIntention.invertIf.id])
        XCTAssertFalse(turned.showsBulb)
        XCTAssertTrue(turned.showsPreview)
        XCTAssertFalse(turned.isEnabled(.invertIf))
        XCTAssertTrue(turned.isEnabled(.addBraces))
        XCTAssertEqual(turned.disabledIDs.sorted(), [JavaIntention.invertIf.id])
    }

    func testInvertIfSwapsTheBranches() async throws {
        let result = try await apply(.invertIf, in: "if (re|ady) go(); else wait();")
        XCTAssertTrue(result.contains("if (!ready) wait(); else go();"), result)
    }

    func testInvertIfIsNotOfferedWithoutAnElse() async throws {
        let actions = try await actions(in: "if (re|ady) go();")
        XCTAssertFalse(actions.contains { $0.kind == JavaIntention.invertIf.kind })
    }

    func testFlipComparisonTurnsTheOperatorAround() async throws {
        let result = try await apply(.flipComparison, in: "return a <| b;")
        XCTAssertTrue(result.contains("return b > a;"), result)
    }

    func testIfElseBecomesAConditionalExpression() async throws {
        let returned = try await apply(.ifToTernary, in: "if (re|ady) return 1; else return 0;")
        XCTAssertTrue(returned.contains("return (ready) ? 1 : 0;"), returned)
        let assigned = try await apply(.ifToTernary, in: "if (re|ady) count = 1; else count = 0;")
        XCTAssertTrue(assigned.contains("count = (ready) ? 1 : 0;"), assigned)
    }

    func testConditionalExpressionBecomesAnIfElse() async throws {
        let returned = try await apply(.ternaryToIf, in: "return re|ady ? 1 : 0;")
        XCTAssertTrue(returned.contains("if (ready) return 1; else return 0;"), returned)
        let assigned = try await apply(.ternaryToIf, in: "count = re|ady ? 1 : 0;")
        XCTAssertTrue(assigned.contains("if (ready) count = 1; else count = 0;"), assigned)
    }

    func testAddAndRemoveBraces() async throws {
        let added = try await apply(.addBraces, in: "if (ready) go|();")
        XCTAssertTrue(added.contains("go();"), added)
        XCTAssertTrue(added.contains("{"), added)
        let removed = try await apply(.removeBraces, in: "if (ready) { go|(); }")
        XCTAssertTrue(removed.contains("if (ready) go();"), removed)
        XCTAssertFalse(removed.contains("if (ready) {"), removed)
    }

    func testSplitAndMergeIf() async throws {
        let split = try await apply(.splitIf, in: "if (a |&& b) go();")
        XCTAssertTrue(split.contains("if (a)"), split)
        XCTAssertTrue(split.contains("if (b) go();"), split)
        let merged = try await apply(.mergeIf, in: "if (a|) { if (b) go(); }")
        XCTAssertTrue(merged.contains("if (a && b) go();"), merged)
    }

    func testDeMorganPushesAndPullsANegation() async throws {
        let pushed = try await apply(.deMorgan, in: "return !(a |&& b);")
        XCTAssertTrue(pushed.contains("return !a || !b;"), pushed)
        let pulled = try await apply(.deMorgan, in: "return !a |&& !b;")
        XCTAssertTrue(pulled.contains("return !(a || b);"), pulled)
    }

    func testSplitAndJoinADeclaration() async throws {
        let split = try await apply(.splitDeclaration, in: "int co|unt = 1;")
        XCTAssertTrue(split.contains("int count;"), split)
        XCTAssertTrue(split.contains("count = 1;"), split)
        let joined = try await apply(.joinDeclaration, in: "int co|unt;\n        count = 1;")
        XCTAssertTrue(joined.contains("int count = 1;"), joined)
        XCTAssertFalse(joined.contains("int count;"), joined)
    }

    func testExpandAndCollapseALambda() async throws {
        let expanded = try await apply(.expandLambda, in: "Object f = x -> x |+ 1;")
        XCTAssertTrue(expanded.contains("{ return x + 1; }"), expanded)
        let collapsed = try await apply(.collapseLambda, in: "Object f = x -> { return x |+ 1; };")
        XCTAssertTrue(collapsed.contains("x -> x + 1"), collapsed)
        XCTAssertFalse(collapsed.contains("return"), collapsed)
    }

    func testLineCommentsBecomeABlockAndBack() async throws {
        let block = try await apply(.lineCommentsToBlock, in: "// o|ne\n        // two")
        XCTAssertTrue(block.contains("/*"), block)
        XCTAssertTrue(block.contains("one"), block)
        XCTAssertTrue(block.contains("two"), block)
        let lines = try await apply(.blockCommentToLines, in: "/* o|ne\n           two */")
        XCTAssertTrue(lines.contains("// one"), lines)
        XCTAssertTrue(lines.contains("// two"), lines)
    }

    func testStringConcatenationBecomesATextBlock() async throws {
        let result = try await apply(.textBlock, in: "String s = \"a\\n\" +| \"b\\n\" + \"c\";")
        XCTAssertTrue(result.contains("\"\"\""), result)
        XCTAssertTrue(result.contains("a"), result)
        XCTAssertTrue(result.contains("b"), result)
    }

    func testExplicitTypeBecomesVar() async throws {
        let result = try await apply(.explicitToVar, in: "String na|me = \"Ada\";")
        XCTAssertTrue(result.contains("var name = \"Ada\";"), result)
    }

    func testVarBecomesTheExplicitType() async throws {
        let result = try await apply(.varToExplicit, in: "var co|unt = 1;")
        XCTAssertTrue(result.contains("int count = 1;"), result)
    }

    func testADiamondStaysExplicit() async throws {
        let actions = try await actions(in: "List<String> xs| = new ArrayList<>();")
        XCTAssertFalse(actions.contains { $0.kind == JavaIntention.explicitToVar.kind })
    }

    func testADisabledIntentionIsLeftOut() async throws {
        var options = JavaIntentionOptions.standard
        options.disabledIDs = [JavaIntention.invertIf.id]
        let actions = try await actions(in: "if (re|ady) go(); else wait();", options: options)
        XCTAssertFalse(actions.contains { $0.kind == JavaIntention.invertIf.kind })
        XCTAssertTrue(actions.contains { $0.kind == JavaIntention.addBraces.kind })
    }

    func testBulbIsYellowForAnIntentionAndRedForAFix() async throws {
        let (source, offset, tree) = try fixture("if (re|ady) go(); else wait();")
        XCTAssertEqual(
            JavaIntentionEngine.bulb(tree: tree, source: source, utf16Offset: offset, options: .standard, diagnostics: []),
            .intention
        )
        let hidden = JavaIntentionOptions(showsBulb: false)
        XCTAssertEqual(
            JavaIntentionEngine.bulb(tree: tree, source: source, utf16Offset: offset, options: hidden, diagnostics: []),
            .none
        )
        let position = JavaNavigationText.position(utf16Offset: offset, in: source)
        let diagnostic = Diagnostic(
            severity: .error, message: "missing", range: TextRange(start: position, end: position), source: "javac"
        )
        XCTAssertEqual(
            JavaIntentionEngine.bulb(tree: tree, source: source, utf16Offset: offset, options: .standard, diagnostics: [diagnostic]),
            .quickFix
        )
    }

    func testTheProviderOmitsADisabledIntentionAndKeepsTheChevron() async throws {
        let provider = JavaCodeActionProvider(index: index)
        let (source, offset, _) = try fixture("if (re|ady) go(); else wait();")
        let caret = JavaNavigationText.position(utf16Offset: offset, in: source)
        let document = Document(
            url: URL(fileURLWithPath: "/T.java"), displayName: "T.java",
            contentSnapshot: TextSnapshot(version: 0, text: source),
            selection: Selection(range: TextRange(start: caret, end: caret)),
            cursor: Cursor(position: caret),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: "java"
        )
        await provider.setIntentionOptions(JavaIntentionOptions(disabledIDs: [JavaIntention.invertIf.id]))
        let hidden = await provider.codeActions(for: document, at: caret, diagnostics: [])
        XCTAssertFalse(hidden.contains { $0.kind == JavaIntention.invertIf.kind })

        await provider.setIntentionOptions(.standard)
        let shown = await provider.codeActions(for: document, at: caret, diagnostics: [])
        let invert = try XCTUnwrap(shown.first { $0.kind == JavaIntention.invertIf.kind })
        XCTAssertFalse(invert.preview?.isEmpty ?? true)
        XCTAssertEqual(invert.options.map(\.command.id), [JavaIntentionCommand.disable, JavaIntentionCommand.configure])
        let bulb = await provider.bulb(for: document, at: caret, diagnostics: [])
        XCTAssertEqual(bulb, .intention)
        await provider.setIntentionOptions(JavaIntentionOptions(showsBulb: false))
        let hiddenBulb = await provider.bulb(for: document, at: caret, diagnostics: [])
        XCTAssertEqual(hiddenBulb, .none)
    }

    // MARK: - Fixtures

    private func apply(_ intention: JavaIntention, in marked: String, options: JavaIntentionOptions = .standard) async throws -> String {
        let (source, _, _) = try fixture(marked)
        let action = try await action(intention, in: marked, options: options)
        return apply(action, to: source)
    }

    private func action(_ intention: JavaIntention, in marked: String, options: JavaIntentionOptions = .standard) async throws -> CodeAction {
        let offered = try await actions(in: marked, options: options)
        return try XCTUnwrap(offered.first { $0.kind == intention.kind }, missing(intention, offered: offered, marked: marked))
    }

    private func actions(in marked: String, options: JavaIntentionOptions = .standard) async throws -> [CodeAction] {
        let (source, offset, tree) = try fixture(marked)
        return await JavaIntentionEngine.actions(
            tree: tree, source: source, utf16Offset: offset, options: options, index: index, fileURL: nil
        )
    }

    private func missing(_ intention: JavaIntention, offered: [CodeAction], marked: String) -> String {
        "\(intention.title) was not offered for \(marked) (\(offered.map(\.title)))"
    }

    private func fixture(_ marked: String) throws -> (source: String, offset: Int, tree: JavaSyntaxTree) {
        let ns = marked as NSString
        let bar = ns.range(of: "|")
        XCTAssertNotEqual(bar.location, NSNotFound, "missing caret in \(marked)")
        let body = ns.replacingCharacters(in: bar, with: "")
        let prefix = "class T {\n    void m() {\n        "
        let source = prefix + body + "\n    }\n}\n"
        let offset = (prefix as NSString).length + bar.location
        let tree = try XCTUnwrap(JavaSyntaxParser().parse(source))
        return (source, offset, tree)
    }

    private func apply(_ action: CodeAction, to source: String) -> String {
        var result = source as NSString
        for edit in action.edits.sorted(by: { $0.range.start.utf16Offset > $1.range.start.utf16Offset }) {
            let range = NSRange(
                location: edit.range.start.utf16Offset, length: edit.range.end.utf16Offset - edit.range.start.utf16Offset
            )
            result = result.replacingCharacters(in: range, with: edit.replacement) as NSString
        }
        return result as String
    }
}
