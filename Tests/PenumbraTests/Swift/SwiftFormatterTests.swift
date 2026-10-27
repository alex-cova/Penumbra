import EditorIntelligence
import XCTest
@testable import SwiftIntelligence

final class SwiftFormatterTests: XCTestCase {
    private func formatted(_ source: String, indent: String = "    ") -> String? {
        SwiftFormatter.format(source, options: SwiftFormattingOptions(indentUnit: indent))
    }

    func testReindentsMisindentedBlock() {
        let source = """
        struct Demo: View {
            var body: some View {
                Form {
                    if settings.provider.hasEndpoint {
                        TextField("Base URL", text: $settings.baseURL)
                            .onSubmit { Task { await refresh() } }

                    Section(settings.flag ? "A \\(settings.host)" : "B (optional)") {
                        SecureField("Key", text: $draft)
                            .onSubmit(saveKey)
                        if let error = settings.error {
                            Text(error)
                        }
                    }
                    }
                }
            }
        }
        """
        let expected = """
        struct Demo: View {
            var body: some View {
                Form {
                    if settings.provider.hasEndpoint {
                        TextField("Base URL", text: $settings.baseURL)
                            .onSubmit { Task { await refresh() } }

                        Section(settings.flag ? "A \\(settings.host)" : "B (optional)") {
                            SecureField("Key", text: $draft)
                                .onSubmit(saveKey)
                            if let error = settings.error {
                                Text(error)
                            }
                        }
                    }
                }
            }
        }
        """
        XCTAssertEqual(formatted(source), expected)
    }

    func testLeavesFormattedCodeAlone() {
        let source = """
        struct Demo: View {
            var body: some View {
                Text("hi")
                    .font(.title)
            }
        }
        """
        XCTAssertEqual(formatted(source), source)
    }

    func testBracesInStringsDoNotAffectDepth() {
        let source = """
        struct Demo {
            let a = "} unbalanced { \\(x)"
            let b = "API key (optional)"
            func f() {
                print("}")
            }
        }
        """
        XCTAssertEqual(formatted(source), source)
    }

    func testMultilineStringBodiesArePreservedVerbatim() {
        let source = """
        struct Demo {
            let text = \"\"\"
                keep   this
              spacing {(untouched)}
              \\(value)
            \"\"\"
            let next = 1
        }
        """
        XCTAssertEqual(formatted(source), source)
    }

    func testSwitchCaseBodiesIndentOnePastTheirLabel() {
        let source = """
        func f(_ x: Int) {
            switch x {
            case 1:
            print("one")
            default:
                print("other")
            }
        }
        """
        let expected = """
        func f(_ x: Int) {
            switch x {
                case 1:
                    print("one")
                default:
                    print("other")
            }
        }
        """
        XCTAssertEqual(formatted(source), expected)
    }

    func testLeadingDotContinuationsIndentOnePastTheReceiver() {
        let source = """
        struct Demo: View {
            var body: some View {
                Text("hi")
                .font(.title)
                .foregroundStyle(.red)
            }
        }
        """
        let expected = """
        struct Demo: View {
            var body: some View {
                Text("hi")
                    .font(.title)
                    .foregroundStyle(.red)
            }
        }
        """
        XCTAssertEqual(formatted(source), expected)
    }

    func testTrimsTrailingWhitespaceAndCollapsesBlankRuns() {
        let source = "struct Demo {\n    let x = 1   \n\n\n\n    let y = 2\n}\n"
        XCTAssertEqual(formatted(source), "struct Demo {\n    let x = 1\n\n\n    let y = 2\n}\n")
    }

    func testSemicolonsArePreserved() {
        // `;` is a hidden `_explicit_semi` with no tree node; the formatter must not eat it.
        let source = """
        struct Demo {
            func f() {
                parts.append(current); current = ""
                if done { finish() }; cleanup()
            }
        }
        """
        XCTAssertEqual(formatted(source), source)
    }

    func testKeepsIntraLineSpacingAsWritten() {
        let source = "struct Demo {\n    func f( a:Int )->Int {\n        return  a+1\n    }\n}\n"
        XCTAssertEqual(formatted(source), source)
    }

    func testRefusesFileWithSyntaxError() {
        XCTAssertNil(formatted("struct Demo {\n    let x = 1\n"))
        XCTAssertNil(formatted("func f( {\n}\n"))
    }

    func testRespectsTheIndentUnit() {
        let source = "struct Demo {\nlet x = 1\n}\n"
        XCTAssertEqual(formatted(source, indent: "\t"), "struct Demo {\n\tlet x = 1\n}\n")
    }

    // MARK: - Provider

    private func document(_ text: String, language: String = "swift") -> Document {
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        return Document(
            displayName: "A.swift", contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: EditorIntelligence.TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 10, height: 10),
            languageIdentifier: language
        )
    }

    private func apply(_ edits: [TextEdit], to text: String) -> String {
        var result = text as NSString
        for edit in edits.sorted(by: { $0.range.start.utf16Offset > $1.range.start.utf16Offset }) {
            result = result.replacingCharacters(
                in: NSRange(location: edit.range.start.utf16Offset, length: edit.range.end.utf16Offset - edit.range.start.utf16Offset),
                with: edit.replacement
            ) as NSString
        }
        return result as String
    }

    func testProviderSupportsOnlySwift() async {
        let provider = SwiftFormattingProvider()
        XCTAssertTrue(provider.supportsFormatting(document("x", language: "swift")))
        XCTAssertFalse(provider.supportsFormatting(document("x", language: "java")))
    }

    func testProviderFormatsDocument() async {
        let provider = SwiftFormattingProvider()
        let text = "struct Demo {\nlet x = 1\n}\n"
        let edits = await provider.formatDocument(document(text))
        XCTAssertEqual(apply(edits, to: text), "struct Demo {\n    let x = 1\n}\n")
    }

    func testProviderFormatsElidedDocumentsThroughTheReader() async {
        let provider = SwiftFormattingProvider()
        let text = "struct Demo {\nlet x = 1\n}\n"
        let ns = text as NSString
        let reader = TextRangeReader(utf16Length: ns.length) { location, length in
            (text as NSString).substring(with: NSRange(location: location, length: length))
        }
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        let elided = Document(
            displayName: "A.swift",
            contentSnapshot: TextSnapshot(version: 0, utf16Length: ns.length, text: nil, rangeReader: reader),
            selection: Selection(range: EditorIntelligence.TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 10, height: 10),
            languageIdentifier: "swift"
        )
        let edits = await provider.formatDocument(elided)
        XCTAssertEqual(apply(edits, to: text), "struct Demo {\n    let x = 1\n}\n")
    }

    /// The real file the editor refused to reformat: the moved `Section` (lines 65-82) and the
    /// `if settings.provider.appleKind == nil` block (92-101) are misindented.
    func testFormatsTheAgentSettingsFixture() throws {
        let source = AgentSettingsFixture.source
        XCTAssertNil(SwiftFormatter.diagnose(source), "refused: \(String(describing: SwiftFormatter.diagnose(source)))")
        let formatted = try XCTUnwrap(formatted(source))
        let lines = formatted.components(separatedBy: "\n")
        func indent(of line: Int) -> Int { lines[line - 1].prefix { $0 == " " }.count }
        // `Section(settings.requiresAPIKey …` sits inside `if settings.provider.hasEndpoint {`.
        XCTAssertEqual(indent(of: 65), indent(of: 62), "line 65 should sit at the same level as the TextField above it")
        XCTAssertEqual(indent(of: 92), indent(of: 91) + 4)
        XCTAssertEqual(SwiftFormatter.format(formatted), formatted, "formatting twice changes nothing")
    }

    func testDiagnoseNamesWhyAFileIsLeftAlone() {
        XCTAssertEqual(SwiftFormatter.diagnose("struct S {\n    let x = 1\n}\n"), nil)
        guard case .syntaxProblem = SwiftFormatter.diagnose("struct S {\n    let x = \n") else {
            return XCTFail("a half-written file should be refused as a syntax problem")
        }
    }

    func testProviderLeavesFormattedDocumentAlone() async {
        let provider = SwiftFormattingProvider()
        let text = "struct Demo {\n    let x = 1\n}\n"
        let edits = await provider.formatDocument(document(text))
        XCTAssertTrue(edits.isEmpty)
    }

    func testProviderSelectionKeepsEveryLineBreak() async {
        let provider = SwiftFormattingProvider()
        let text = "struct Demo {\nlet x = 1\n\n\nlet y = 2\n}\n"
        let ns = text as NSString
        let range = EditorIntelligence.TextRange(
            start: TextPosition(line: 0, column: 0, utf16Offset: 0),
            end: TextPosition(line: 4, column: 0, utf16Offset: ns.length)
        )
        let edits = await provider.formatSelection(in: document(text), range: range)
        let result = apply(edits, to: text)
        XCTAssertEqual(result.components(separatedBy: "\n").count, text.components(separatedBy: "\n").count)
        XCTAssertEqual(result, "struct Demo {\n    let x = 1\n\n\n    let y = 2\n}\n")
    }
}
