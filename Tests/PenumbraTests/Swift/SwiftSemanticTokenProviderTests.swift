import EditorIntelligence
import XCTest
@testable import SwiftIntelligence

/// The semantic pass must not paint over the grammar's colors: an uppercase callee (`Text(…)`)
/// is a type construction or a type-like DSL use, and the tree-sitter query already colors
/// SwiftUI views as types. Only lowercase (function-shaped) calls get `function.call` here.
final class SwiftSemanticTokenProviderTests: XCTestCase {
    private let source = """
    struct Demo: View {
        var body: some View {
            Section("Header") {
                Text("Hello")
                refreshModelsIfOllama()
                settings.removeAPIKey()
            }
        }
    }
    """

    private func tokens() async -> [SemanticHighlight] {
        await SwiftSemanticTokenProvider().semanticHighlights(forSource: source) ?? []
    }

    private func highlights(at word: String, occurrence: Int = 0) async -> [String] {
        let ns = source as NSString
        var search = NSRange(location: 0, length: ns.length)
        var found = NSRange(location: NSNotFound, length: 0)
        for _ in 0 ... occurrence {
            found = ns.range(of: word, options: [], range: search)
            guard found.location != NSNotFound else { return [] }
            search = NSRange(location: found.upperBound, length: ns.length - found.upperBound)
        }
        let tokens = await tokens()
        return tokens
            .filter { $0.range.lowerBound <= found.location && found.location < $0.range.upperBound }
            .map(\.highlightName)
    }

    func testUppercaseViewCallsAreLeftToTheGrammar() async {
        let section = await highlights(at: "Section")
        XCTAssertEqual(section, [])
        // `Text("Hello")`: the only `Text` occurrence.
        let text = await highlights(at: "Text")
        XCTAssertEqual(text, [])
    }

    /// Every token must be a whole identifier of the text it was computed for. A range that starts
    /// or ends inside a word (`has|Endpoint`) means offsets were measured against different text.
    func testTokensCoverWholeIdentifiersInTheAgentSettingsFixture() async throws {
        let text = AgentSettingsFixture.source
        let ns = text as NSString
        let result = await SwiftSemanticTokenProvider().semanticHighlights(forSource: text)
        let tokens = try XCTUnwrap(result)
        XCTAssertFalse(tokens.isEmpty)
        func isIdentifier(_ unit: unichar) -> Bool {
            guard let scalar = Unicode.Scalar(unit) else { return false }
            return scalar == "_" || CharacterSet.alphanumerics.contains(scalar)
        }
        var broken: [String] = []
        for token in tokens {
            let range = NSRange(location: token.range.lowerBound, length: token.range.count)
            guard range.length > 0, range.upperBound <= ns.length else {
                broken.append("\(token.highlightName) \(range) out of bounds")
                continue
            }
            let word = ns.substring(with: range)
            let before = range.location > 0 ? ns.character(at: range.location - 1) : 0x20
            let after = range.upperBound < ns.length ? ns.character(at: range.upperBound) : 0x20
            if !word.unicodeScalars.allSatisfy({ $0 == "_" || CharacterSet.alphanumerics.contains($0) })
                || isIdentifier(before) || isIdentifier(after) {
                let line = ns.substring(to: range.location).components(separatedBy: "\n").count
                broken.append("line \(line): \(token.highlightName) '\(word)'")
            }
        }
        XCTAssertTrue(broken.isEmpty, broken.prefix(20).joined(separator: "\n"))
    }

    func testLowercaseCallsStayFunctionCalls() async {
        let refresh = await highlights(at: "refreshModelsIfOllama")
        XCTAssertEqual(refresh, ["function.call"])
    }

    func testMemberCallsStayFunctionCalls() async {
        let remove = await highlights(at: "removeAPIKey")
        XCTAssertEqual(remove, ["function.call"])
    }
}
