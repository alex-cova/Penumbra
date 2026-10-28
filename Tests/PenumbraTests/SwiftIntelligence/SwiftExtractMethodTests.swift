import Foundation
import SwiftIntelligence
import XCTest

/// Native Extract Method: the exact rewrite a selection produces, and what it refuses.
/// The `⟦…⟧` marker is the selection (a UTF-8 byte range); helpers live on `SwiftRefactoringTests`.
final class SwiftExtractMethodTests: XCTestCase {
    private func extract(_ marked: String, name: String) -> String? {
        let parsed = SwiftRefactoringTests.parse(marked)
        return SwiftRefactoringTests.apply(
            SwiftExtractMethod.edits(in: parsed.text, selection: parsed.selection ?? 0 ..< 0, name: name),
            to: parsed.text
        )
    }

    private func refusal(_ marked: String, name: String = "extracted") -> String? {
        let parsed = SwiftRefactoringTests.parse(marked)
        if case .failure(let failure) = SwiftExtractMethod.edits(
            in: parsed.text, selection: parsed.selection ?? 0 ..< 0, name: name
        ) {
            return failure.message
        }
        return nil
    }

    private func suggested(_ marked: String) -> String? {
        let parsed = SwiftRefactoringTests.parse(marked)
        return SwiftExtractMethod.suggestedName(in: parsed.text, selection: parsed.selection ?? 0 ..< 0)
    }

    // MARK: - Selections

    func testExtractsWholeStatements() {
        XCTAssertEqual(
            extract(
                "func f(first: String, second: String) {\n    ⟦let message = first + second\n    print(message)⟧\n}\n",
                name: "log"
            ),
            "func f(first: String, second: String) {\n    log(first, second)\n}\nprivate func log(_ first: String, _ second: String) {\n    let message = first + second\n    print(message)\n}\n"
        )
    }

    func testExtractsAValuedExpression() {
        XCTAssertEqual(
            extract("func f() {\n    print(⟦\"hello\"⟧)\n}\n", name: "greeting"),
            "func f() {\n    print(greeting())\n}\nprivate func greeting() -> String {\n    return \"hello\"\n}\n"
        )
    }

    func testExtractsADiscardedExpression() {
        XCTAssertEqual(
            extract("func f() {\n    ⟦print(\"hi\")⟧\n}\n", name: "log"),
            "func f() {\n    log()\n}\nprivate func log() {\n    print(\"hi\")\n}\n"
        )
    }

    func testExtractsADeclaredWithoutAValueAssignedInside() {
        XCTAssertEqual(
            extract("func f(flag: Bool, text: String) -> String {\n    ⟦let index: Int\n    if flag {\n        index = 1\n    } else {\n        index = 2\n    }⟧\n    return String(text.prefix(index))\n}\n", name: "loaded"),
            "func f(flag: Bool, text: String) -> String {\n    let index = loaded(flag)\n    return String(text.prefix(index))\n}\nprivate func loaded(_ flag: Bool) -> Int {\n    let index: Int\n    if flag {\n        index = 1\n    } else {\n        index = 2\n    }\n    return index\n}\n"
        )
    }

    func testExtractsABareThrow() {
        XCTAssertEqual(
            extract("struct S {\n    mutating func encode() throws {\n        ⟦throw EncodingError.failed(\"need content\")⟧\n        print(\"done\")\n    }\n}\n", name: "fail"),
            "struct S {\n    mutating func encode() throws {\n        try fail()\n        print(\"done\")\n    }\n    private mutating func fail() throws {\n        throw EncodingError.failed(\"need content\")\n    }\n}\n"
        )
    }

    func testExtractsTheWholeBodyAsAnImplicitReturn() {
        XCTAssertEqual(
            extract("func f(position: TextPosition) -> LSPPosition {\n    ⟦LSPPosition(line: position.line, character: position.column)⟧\n}\n", name: "converted"),
            "func f(position: TextPosition) -> LSPPosition {\n    return converted(position)\n}\nprivate func converted(_ position: TextPosition) -> LSPPosition {\n    return LSPPosition(line: position.line, character: position.column)\n}\n"
        )
    }

    func testExtractsAnInoutVariable() {
        XCTAssertEqual(
            extract("func f() {\n    var count = 0\n    ⟦count += 1\n    print(count)⟧\n}\n", name: "bump"),
            "func f() {\n    var count = 0\n    bump(&count)\n}\nprivate func bump(_ count: inout Int) {\n    count += 1\n    print(count)\n}\n"
        )
    }

    func testExtractsAReturnedOutput() {
        XCTAssertEqual(
            extract(
                "func f() -> [Int] {\n    ⟦let numbers = [1, 2, 3]⟧\n    return numbers\n}\n",
                name: "makeNumbers"
            ),
            "func f() -> [Int] {\n    let numbers = makeNumbers()\n    return numbers\n}\nprivate func makeNumbers() -> [Int] {\n    let numbers = [1, 2, 3]\n    return numbers\n}\n"
        )
    }

    func testExtractsThrowingAndAsync() {
        XCTAssertEqual(
            extract("func f() throws {\n    ⟦let data = try load()\n    print(data)⟧\n}\n", name: "read"),
            "func f() throws {\n    try read()\n}\nprivate func read() throws {\n    let data = try load()\n    print(data)\n}\n"
        )
        XCTAssertEqual(
            extract("func f() async {\n    ⟦let data = await fetch()\n    print(data)⟧\n}\n", name: "read"),
            "func f() async {\n    await read()\n}\nprivate func read() async {\n    let data = await fetch()\n    print(data)\n}\n"
        )
    }

    func testCopiesStaticMutatingAndGlobalActor() {
        XCTAssertEqual(
            extract("struct S {\n    static func f() {\n        ⟦print(1)⟧\n    }\n}\n", name: "log"),
            "struct S {\n    static func f() {\n        log()\n    }\n    private static func log() {\n        print(1)\n    }\n}\n"
        )
        XCTAssertEqual(
            extract("struct S {\n    var count = 0\n    mutating func bump() {\n        ⟦count += 1⟧\n    }\n}\n", name: "step"),
            "struct S {\n    var count = 0\n    mutating func bump() {\n        step()\n    }\n    private mutating func step() {\n        count += 1\n    }\n}\n"
        )
        XCTAssertEqual(
            extract("@MainActor func f() {\n    ⟦print(1)⟧\n}\n", name: "log"),
            "@MainActor func f() {\n    log()\n}\n@MainActor private func log() {\n    print(1)\n}\n"
        )
    }

    // MARK: - Names

    func testSuggestsNames() {
        XCTAssertEqual(suggested("func f(name: String) {\n    ⟦print(name)⟧\n}\n"), "print2")
        XCTAssertEqual(suggested("func f() {\n    ⟦print(\"hi\")⟧\n}\n"), "print2")
        XCTAssertEqual(suggested("func f() {\n    let y = ⟦make()⟧\n}\n"), "make2")
        XCTAssertEqual(suggested("func f() {\n    return a + ⟦b⟧ * c\n}\n"), "bValue")
    }

    // MARK: - Refusals

    func testRefusesControlFlowThatLeaves() {
        XCTAssertEqual(
            refusal("func f(c: Bool) -> Int {\n    ⟦if c { return 1 }\n    return 2⟧\n}\n"),
            "Cannot extract a 'return' statement."
        )
        XCTAssertEqual(
            refusal("func f(items: [Int]) {\n    for x in items {\n        ⟦if x > 0 { break }⟧\n    }\n}\n"),
            "Cannot extract a 'break' or 'continue' statement."
        )
        XCTAssertEqual(
            refusal("func f() {\n    ⟦defer { cleanup() }\n    work()⟧\n}\n"),
            "Cannot extract a 'defer' statement."
        )
    }

    func testRefusesClosuresImplicitNamesAndAssignments() {
        XCTAssertEqual(
            refusal("func f(items: [Int]) {\n    items.forEach { x in\n        ⟦print(x)⟧\n    }\n}\n"),
            "Cannot extract code from inside a closure."
        )
        XCTAssertEqual(
            refusal("func f(list: [Int]) -> [Int] {\n    return ⟦list.map { $0 * 2 }⟧\n}\n"),
            "Cannot extract code that uses '$0'."
        )
        XCTAssertEqual(
            refusal("func f() {\n    do {\n        try work()\n    } catch {\n        ⟦print(error)⟧\n    }\n}\n"),
            "Cannot extract code that uses 'error'."
        )
        XCTAssertEqual(
            refusal("func f() {\n    var a = 0\n    ⟦a⟧ = 1\n}\n"),
            "Cannot extract an assignment target."
        )
        XCTAssertEqual(
            refusal("func f() throws -> Data {\n    return try ⟦load()⟧\n}\n"),
            "Select the whole 'try' expression."
        )
    }

    func testRefusesLocalsGenericsTypesAndBadNames() {
        XCTAssertEqual(
            refusal("func f() {\n    func helper() {}\n    ⟦helper()⟧\n}\n"),
            "Cannot extract code that uses 'helper', a local function."
        )
        XCTAssertEqual(
            refusal("func f(hex: String) -> String {\n    func toHex(_ v: Double) -> String {\n        return ⟦String(v)⟧\n    }\n    return toHex(1.0)\n}\n"),
            "Cannot extract code from inside a local function."
        )
        XCTAssertEqual(
            refusal("func f<T>(x: T) {\n    ⟦print(x)⟧\n}\n"),
            "Cannot extract code that mentions generic parameter 'T'."
        )
        XCTAssertEqual(
            refusal("func f(a: Int, b: Int) -> Int {\n    return ⟦a + b⟧\n}\n"),
            "Cannot tell the type of the extracted expression; add an explicit type or use SourceKit's Extract Method."
        )
        XCTAssertEqual(
            refusal("func f(symbols: [Symbol]) -> Set<Symbol> {\n    return ⟦Set(symbols)⟧\n}\n"),
            "Cannot tell the type of the extracted expression; add an explicit type or use SourceKit's Extract Method."
        )
        XCTAssertEqual(
            refusal("func f(attributed: CFAttributedString) -> CTLine {\n    return ⟦CTLineCreateWithAttributedString(attributed)⟧\n}\n"),
            "Cannot tell the type of the extracted expression; add an explicit type or use SourceKit's Extract Method."
        )
        XCTAssertEqual(
            refusal("func f(flag: Bool) -> Int {\n    ⟦let value: Int⟧\n    if flag {\n        return value\n    }\n    return 0\n}\n"),
            "Cannot return 'value' from the selection: it is declared without a value here."
        )
        XCTAssertEqual(
            refusal("func f(text: String, offset: Int) -> String {\n    let index: String.Index\n    ⟦index = text.startIndex⟧\n    return String(text[index...])\n}\n"),
            "Cannot extract code that assigns to 'index', which is not mutable here."
        )
        XCTAssertEqual(
            refusal("func f(x: Int) {\n    ⟦x = 1⟧\n    print(x)\n}\n"),
            "Cannot extract code that assigns to 'x', which is not mutable here."
        )
        XCTAssertEqual(
            refusal("func f() -> Int {\n    ⟦print(1)⟧\n}\n"),
            "Cannot extract the whole body of a function that returns a value."
        )
        XCTAssertEqual(
            refusal("func f(flag: Bool) throws {\n    guard flag else {\n        ⟦throw EncodingError.failed⟧\n    }\n}\n"),
            "Cannot extract the whole body of a 'guard'."
        )
        XCTAssertEqual(
            refusal("func f(flag: Bool) throws {\n    guard flag else {\n        ⟦try risky()⟧\n        return\n    }\n}\n"),
            "Cannot extract throwing code from a 'guard' body."
        )
        XCTAssertEqual(
            refusal("struct S {\n    func f() {}\n    func g() {\n        ⟦print(1)⟧\n    }\n}\n", name: "f"),
            "'f' already exists in this type."
        )
        XCTAssertEqual(
            refusal("func f() {\n    ⟦print(1)⟧\n}\n", name: "123"),
            "'123' is not a valid name."
        )
    }
}
