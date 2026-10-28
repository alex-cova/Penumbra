import EditorIntelligence
import Foundation
import SwiftIntelligence
import XCTest

/// Safe delete: the exact text a removal leaves, and what it refuses. The `‸` marker is the caret
/// (a UTF-8 offset, as the editor passes it); the helpers live on `SwiftRefactoringTests`.
final class SwiftSafeDeleteTests: XCTestCase {
    private func remove(_ marked: String) -> String? {
        let parsed = SwiftRefactoringTests.parse(marked)
        return SwiftRefactoringTests.apply(SwiftSafeDelete.edits(in: parsed.text, caret: parsed.caret), to: parsed.text)
    }

    private func refusal(_ marked: String) -> String? {
        let parsed = SwiftRefactoringTests.parse(marked)
        if case .failure(let failure) = SwiftSafeDelete.edits(in: parsed.text, caret: parsed.caret) {
            return failure.message
        }
        return nil
    }

    // MARK: - Removals

    func testDeletesAFunctionWithItsDocComment() {
        XCTAssertEqual(
            remove("struct S {\n    /// Does the thing.\n    func ‸helper() {}\n    func run() {}\n}\n"),
            "struct S {\n    func run() {}\n}\n"
        )
    }

    func testTakesOneSurroundingBlankLine() {
        // The following blank goes, so no double gap remains.
        XCTAssertEqual(remove("func ‸a() {}\n\nfunc b() {}\n"), "func b() {}\n")
        // None follows: the preceding one goes instead.
        XCTAssertEqual(remove("func a() {}\n\nfunc ‸b() {}\n"), "func a() {}\n")
        // Both sides: the following one goes and the gap stays single.
        XCTAssertEqual(remove("func a() {}\n\nfunc ‸b() {}\n\nfunc c() {}\n"), "func a() {}\n\nfunc c() {}\n")
    }

    func testTakesAttributesAndBlockDocComments() {
        XCTAssertEqual(
            remove("/// Old.\n@available(*, deprecated)\nfunc ‸old() {}\nfunc f() {}\n"),
            "func f() {}\n"
        )
        XCTAssertEqual(
            remove("/**\n Returns nothing.\n */\nfunc ‸nothing() {}\nfunc f() {}\n"),
            "func f() {}\n"
        )
    }

    func testKeepsMarkSuppressionAndPlainCommentsAbove() {
        XCTAssertEqual(
            remove("// MARK: - Helpers\n\nfunc ‸b() {}\nfunc c() {}\n"),
            "// MARK: - Helpers\nfunc c() {}\n"
        )
        XCTAssertEqual(
            remove("// umbra:disable unused-declaration\nfunc ‸orphan() {}\n"),
            "// umbra:disable unused-declaration\n"
        )
        XCTAssertEqual(
            remove("// A note.\nfunc ‸b() {}\nfunc c() {}\n"),
            "// A note.\nfunc c() {}\n"
        )
    }

    func testDeletesTypesVariablesAndSingleEnumCases() {
        XCTAssertEqual(remove("private struct ‸Hidden {}\nfunc f() {}\n"), "func f() {}\n")
        XCTAssertEqual(remove("var ‸cache = 1\nfunc f() {}\n"), "func f() {}\n")
        XCTAssertEqual(remove("enum E {\n    case ‸a\n    case b\n}\n"), "enum E {\n    case b\n}\n")
        XCTAssertEqual(remove("typealias ‸Alias = Int\nfunc f() -> Int { 1 }\n"), "func f() -> Int { 1 }\n")
    }

    // MARK: - Refusals

    func testRefusesSharedBindingsSharedCasesOverridesAndRequirements() {
        XCTAssertEqual(refusal("struct S {\n    var ‸a = 1, b = 2\n}\n"), "'a' is declared with other names.")
        XCTAssertEqual(refusal("enum E {\n    case ‸a, b\n}\n"), "'a' shares its case with other cases.")
        XCTAssertEqual(
            refusal("class B { func f() {} }\nclass D: B {\n    override func ‸f() {}\n}\n"),
            "'f' overrides another declaration."
        )
        XCTAssertEqual(refusal("protocol P {\n    func ‸f()\n}\n"), "'f' is a protocol requirement.")
    }

    func testRefusesSharedLinesAndCaretsOffTheName() {
        XCTAssertEqual(
            refusal("struct S { func ‸helper() {} }\n"), "'helper' shares its line with other code."
        )
        XCTAssertEqual(
            refusal("func f() {\n    print(‸1)\n}\n"),
            "Place the caret on the name of a function, variable, type or enum case to delete."
        )
    }
}
