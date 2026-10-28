import EditorIntelligence
import Foundation
import SwiftIntelligence
import XCTest

/// The native Swift refactorings, one at a time: the exact text they leave, and what they refuse. A
/// marker `⟦…⟧` is the selection and `‸` the caret. Every case is also compiled before and after
/// (`SwiftRefactoringCompileTests`), so a refactoring that changes meaning shows up as an error.
final class SwiftRefactoringTests: XCTestCase {
    struct Marked {
        var text: String
        var selection: Range<Int>?
        var caret: Int
    }

    /// The source without its markers, and where they were (UTF-8 offsets).
    static func parse(_ marked: String) -> Marked {
        var bytes: [UInt8] = []
        var selectionStart: Int?
        var selection: Range<Int>?
        var caret: Int?
        for scalar in marked.unicodeScalars {
            switch scalar {
            case "⟦": selectionStart = bytes.count
            case "⟧": if let start = selectionStart { selection = start ..< bytes.count }
            case "‸": caret = bytes.count
            default: bytes.append(contentsOf: Array(String(scalar).utf8))
            }
        }
        return Marked(text: String(decoding: bytes, as: UTF8.self), selection: selection, caret: caret ?? selection?.lowerBound ?? 0)
    }

    static func apply(_ result: SwiftRefactoringResult, to text: String) -> String? {
        guard case .success(let edits) = result else { return nil }
        var bytes = Array(text.utf8)
        for edit in edits.sorted(by: { $0.bytes.lowerBound > $1.bytes.lowerBound }) {
            bytes.replaceSubrange(edit.bytes, with: Array(edit.replacement.utf8))
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func introduce(_ marked: String, name: String = "value") -> String? {
        let parsed = Self.parse(marked)
        return Self.apply(SwiftIntroduceVariable.edits(in: parsed.text, selection: parsed.selection ?? 0 ..< 0, name: name), to: parsed.text)
    }

    private func refusal(_ result: SwiftRefactoringResult) -> String? {
        if case .failure(let failure) = result { return failure.message }
        return nil
    }

    // MARK: - Introduce variable

    func testIntroducesAVariableAboveTheStatement() {
        XCTAssertEqual(
            introduce("func f(a: Int, b: Int) -> Int {\n    let y = 1\n    return ⟦a * b⟧ + y\n}\n", name: "product"),
            "func f(a: Int, b: Int) -> Int {\n    let y = 1\n    let product = a * b\n    return product + y\n}\n"
        )
    }

    func testAPreciseSelectionOfAnOperandOfALongerExpression() {
        XCTAssertEqual(
            introduce("func f(a: Int, b: Int, c: Int) -> Int {\n    return a + ⟦b * c⟧\n}\n", name: "product"),
            "func f(a: Int, b: Int, c: Int) -> Int {\n    let product = b * c\n    return a + product\n}\n"
        )
        // `a + b` is not an operand of `a + b * c`, so it is not a node and cannot be selected.
        let notANode = Self.parse("func f(a: Int, b: Int, c: Int) -> Int {\n    return ⟦a + b⟧ * c\n}\n")
        XCTAssertNotNil(refusal(SwiftIntroduceVariable.edits(in: notANode.text, selection: notANode.selection!, name: "x")))
        let parenthesized = Self.parse("func f(a: Int, b: Int, c: Int) -> Int {\n    return (⟦a + b⟧) * c\n}\n")
        XCTAssertNotNil(Self.apply(SwiftIntroduceVariable.edits(in: parenthesized.text, selection: parenthesized.selection!, name: "x"), to: parenthesized.text))
        let wrong = Self.parse("func f(a: Int, b: Int, c: Int) -> Int {\n    return a + ⟦b * c + 1⟧\n}\n")
        XCTAssertNotNil(refusal(SwiftIntroduceVariable.edits(in: wrong.text, selection: wrong.selection!, name: "x")))
    }

    func testABodyThatIsOneExpressionKeepsReturningIt() {
        XCTAssertEqual(
            introduce("func f(a: Int) -> Int {\n    ⟦a * 2⟧ + 1\n}\n", name: "doubled"),
            "func f(a: Int) -> Int {\n    let doubled = a * 2\n    return doubled + 1\n}\n"
        )
        XCTAssertEqual(
            introduce("func f(items: [String]) -> [Int] {\n    items.map { ⟦$0.count⟧ }\n}\n", name: "length"),
            "func f(items: [String]) -> [Int] {\n    items.map { let length = $0.count; return length }\n}\n"
        )
    }

    func testAVoidBodyIsNotGivenAReturn() {
        XCTAssertEqual(
            introduce("func f(a: Int) {\n    print(⟦a * 2⟧)\n}\n", name: "doubled"),
            "func f(a: Int) {\n    let doubled = a * 2\n    print(doubled)\n}\n"
        )
        XCTAssertEqual(
            introduce("func f(items: [Int]) {\n    items.forEach { print(⟦$0 * 2⟧) }\n}\n", name: "doubled"),
            "func f(items: [Int]) {\n    items.forEach { let doubled = $0 * 2; print(doubled) }\n}\n"
        )
        // A closure passed to something unknown might return a value or nothing: no guess.
        let unknown = Self.parse("func f(items: [Int]) {\n    run { print(⟦items.count⟧) }\n}\nfunc run(_ body: () -> Void) {}\n")
        XCTAssertNotNil(refusal(SwiftIntroduceVariable.edits(in: unknown.text, selection: unknown.selection!, name: "n")))
    }

    func testTryAndAwaitTravelWithTheExpression() {
        XCTAssertEqual(
            introduce("func f() throws -> Int {\n    return try ⟦compute(1)⟧ + 1\n}\nfunc compute(_ x: Int) throws -> Int { x }\n", name: "n"),
            "func f() throws -> Int {\n    let n = try compute(1)\n    return try n + 1\n}\nfunc compute(_ x: Int) throws -> Int { x }\n"
        )
    }

    func testAConditionBeforeTheIfItIsIn() {
        XCTAssertEqual(
            introduce("func f(a: Int) {\n    if ⟦a * 2⟧ > 4 { print(a) }\n}\n", name: "doubled"),
            "func f(a: Int) {\n    let doubled = a * 2\n    if doubled > 4 { print(a) }\n}\n"
        )
    }

    func testRefusesWhereHoistingChangesWhatRuns() {
        for source in [
            "func f(a: String?) -> Bool { return a != nil && ⟦a!.isEmpty⟧ }\n",
            "func f(a: Int?, b: Int) -> Int { return a ?? ⟦b * 2⟧ }\n",
            "func f(c: Bool, a: Int) -> Int { return c ? ⟦a * 2⟧ : 0 }\n",
            "func f(a: Int?) {\n    if a != nil, ⟦a! > 1⟧ { }\n}\n",
            "func f(a: Int) {\n    var n = 0\n    while ⟦n * 2⟧ < a { n += 1 }\n}\n",
            "func f(a: Int, b: Bool) {\n    if b { } else if ⟦a * 2⟧ > 1 { }\n}\n",
            "func f(a: Int) {\n    assert(⟦a * 2⟧ > 1)\n}\n",
        ] {
            let parsed = Self.parse(source)
            XCTAssertNotNil(refusal(SwiftIntroduceVariable.edits(in: parsed.text, selection: parsed.selection!, name: "x")), source)
        }
    }

    func testRefusesExpressionsWhoseTypeComesFromTheirContext() {
        for source in [
            "func f() { let d: Double = ⟦1⟧ }\n",
            "func f() { let d: Double? = ⟦nil⟧ }\n",
            "func f() { let a: [Double] = ⟦[1, 2]⟧ }\n",
            "func f() { let c: (Int) -> Int = ⟦{ $0 }⟧ }\n",
            "func f(a: Int) { var b = 0; ⟦b⟧ = a }\n",
            "func f() { let c = ⟦Int⟧.max }\n",
        ] {
            let parsed = Self.parse(source)
            XCTAssertNotNil(refusal(SwiftIntroduceVariable.edits(in: parsed.text, selection: parsed.selection!, name: "x")), source)
        }
    }

    func testSuggestedNamesAvoidTheNamesInUse() {
        let parsed = Self.parse("func f(user: User) {\n    print(⟦user.makeName()⟧)\n}\nstruct User { func makeName() -> String { \"\" } }\n")
        XCTAssertEqual(SwiftIntroduceVariable.suggestedName(in: parsed.text, selection: parsed.selection!), "name")
        let taken = Self.parse("func f(user: User) {\n    let name = 1\n    print(⟦user.makeName()⟧, name)\n}\nstruct User { func makeName() -> String { \"\" } }\n")
        XCTAssertEqual(SwiftIntroduceVariable.suggestedName(in: taken.text, selection: taken.selection!), "name2")
    }

    func testRefusesAnInvalidName() {
        let parsed = Self.parse("func f(a: Int) { print(⟦a * 2⟧) }\n")
        XCTAssertNotNil(refusal(SwiftIntroduceVariable.edits(in: parsed.text, selection: parsed.selection!, name: "class")))
        XCTAssertNotNil(refusal(SwiftIntroduceVariable.edits(in: parsed.text, selection: parsed.selection!, name: "1x")))
    }

    // MARK: - Inline variable

    private func inline(_ marked: String) -> String? {
        let parsed = Self.parse(marked)
        return Self.apply(SwiftInlineVariable.edits(in: parsed.text, caret: parsed.caret), to: parsed.text)
    }

    private func inlineRefusal(_ marked: String) -> String? {
        let parsed = Self.parse(marked)
        return refusal(SwiftInlineVariable.edits(in: parsed.text, caret: parsed.caret))
    }

    func testInlinesAValueIntoItsUsesAndRemovesTheDeclaration() {
        XCTAssertEqual(
            inline("func f(a: Int, b: Int) -> Int {\n    let ‸sum = a + b\n    return sum * 2\n}\n"),
            "func f(a: Int, b: Int) -> Int {\n    return (a + b) * 2\n}\n"
        )
        XCTAssertEqual(
            inline("func f(v: [Int]) -> Int {\n    let n = v.count\n    return ‸n + n\n}\n"),
            "func f(v: [Int]) -> Int {\n    return v.count + v.count\n}\n"
        )
        XCTAssertEqual(
            inline("func f(a: String, b: String) {\n    let full = a + b\n    print(\"\\(‸full)\")\n}\n"),
            "func f(a: String, b: String) {\n    print(\"\\(a + b)\")\n}\n"
        )
    }

    func testAValueThatDoesSomethingMovesOnlyIntoTheNextStatement() {
        XCTAssertEqual(
            inline("func f() -> Int {\n    let ‸r = compute()\n    return r + 1\n}\nfunc compute() -> Int { 1 }\n"),
            "func f() -> Int {\n    return compute() + 1\n}\nfunc compute() -> Int { 1 }\n"
        )
        XCTAssertNotNil(inlineRefusal("func f() -> Int {\n    let ‸r = compute()\n    print(1)\n    return r + 1\n}\nfunc compute() -> Int { 1 }\n"))
        XCTAssertNotNil(inlineRefusal("func f() {\n    let ‸r = compute()\n    print(r, r)\n}\nfunc compute() -> Int { 1 }\n"))
        XCTAssertNotNil(inlineRefusal("func f(xs: [Int]) {\n    let ‸r = compute()\n    xs.forEach { print($0 + r) }\n}\nfunc compute() -> Int { 1 }\n"))
        XCTAssertNotNil(inlineRefusal("func f(c: Bool) {\n    let ‸r = compute()\n    print(c && r > 0)\n}\nfunc compute() -> Int { 1 }\n".replacingOccurrences(of: "r > 0", with: "r > 0")))
    }

    func testInlineRefusesWhatItCouldChange() {
        XCTAssertNotNil(inlineRefusal("func f(a: Int) -> Int {\n    var ‸x = a + 1\n    return x\n}\n"))
        XCTAssertNotNil(inlineRefusal("func f(a: Int) -> Int {\n    let ‸x: Double = 1\n    return Int(x)\n}\n"))
        XCTAssertNotNil(inlineRefusal("func f(a: Int) {\n    let ‸x = a + 1\n}\n"))
        XCTAssertNotNil(inlineRefusal("func f(a: Int, o: Int?) -> Int {\n    let ‸y = a + 1\n    if let a = o { return a + y }\n    return y\n}\n"))
        XCTAssertNotNil(inlineRefusal("func f(a: Int) -> () -> Int {\n    let ‸y = a + 1\n    return { y }\n}\n"))
    }

    // MARK: - if / guard

    private func convert(_ marked: String) -> String? {
        let parsed = Self.parse(marked)
        return Self.apply(SwiftConditionalConversion.edits(in: parsed.text, caret: parsed.caret), to: parsed.text)
    }

    func testIfLetAtTheEndOfAVoidFunctionBecomesGuard() {
        XCTAssertEqual(
            convert("func f(x: Int?) {\n    print(0)\n    ‸if let x = x {\n        print(x)\n        print(x + 1)\n    }\n}\n"),
            "func f(x: Int?) {\n    print(0)\n    guard let x = x else { return }\n    print(x)\n    print(x + 1)\n}\n"
        )
        XCTAssertEqual(
            convert("func f(xs: [Int?]) {\n    for x in xs {\n        ‸if let x = x {\n            print(x)\n        }\n    }\n}\n"),
            "func f(xs: [Int?]) {\n    for x in xs {\n        guard let x = x else { continue }\n        print(x)\n    }\n}\n"
        )
    }

    func testIfLetIsKeptWhenGuardWouldNotBeEquivalent() {
        for source in [
            "func f(x: Int?) {\n    ‸if let x = x {\n        print(x)\n    } else {\n        print(0)\n    }\n}\n",
            "func f(x: Int?) {\n    ‸if let x = x {\n        print(x)\n    }\n    print(0)\n}\n",
            "func f(x: Int?) -> Int {\n    ‸if let x = x {\n        return x\n    }\n}\n",
            "func f(x: Int?) {\n    let y = 1\n    ‸if let y = x {\n        print(y)\n    }\n}\n",
            "func f(x: Int?) {\n    ‸if x != nil {\n        print(0)\n    }\n}\n",
        ] {
            let parsed = Self.parse(source)
            XCTAssertNotNil(refusal(SwiftConditionalConversion.edits(in: parsed.text, caret: parsed.caret)), source)
        }
    }

    func testGuardThatOnlyLeavesBecomesIfLet() {
        XCTAssertEqual(
            convert("func f(x: Int?) {\n    ‸guard let x = x else { return }\n    print(x)\n    print(x + 1)\n}\n"),
            "func f(x: Int?) {\n    if let x = x {\n        print(x)\n        print(x + 1)\n    }\n}\n"
        )
        XCTAssertNotNil(refusal(SwiftConditionalConversion.edits(
            in: Self.parse("func f(x: Int?) {\n    guard let x = x else { print(0); return }\n    print(x)\n}\n").text, caret: 28
        )))
    }

    func testGuardInsideAnotherStatementOrLeavingTheWrongThingStaysAGuard() {
        for source in [
            // Leaving early also skips `print(2)`, which an `if` would run.
            "func f(c: Bool, x: Int?) {\n    if c {\n        ‸guard let x = x else { return }\n        print(x)\n    }\n    print(2)\n}\n",
            "func f(xs: [Int?]) {\n    for x in xs {\n        if x == nil {\n            ‸guard let y = x else { continue }\n            print(y)\n        }\n        print(1)\n    }\n}\n",
            // `break` ends the loop; an `if` would go on with the next element.
            "func f(xs: [Int?]) {\n    for x in xs {\n        ‸guard let y = x else { break }\n        print(y)\n    }\n}\n",
            // `return` inside a loop leaves the function; the rest of the function would still run after an `if`.
            "func f(xs: [Int?]) {\n    for x in xs {\n        ‸guard let y = x else { return }\n        print(y)\n    }\n    print(0)\n}\n",
        ] {
            let parsed = Self.parse(source)
            XCTAssertNotNil(refusal(SwiftConditionalConversion.edits(in: parsed.text, caret: parsed.caret)), source)
        }
    }

    // MARK: - Add explicit type

    private func addType(_ marked: String) -> String? {
        let parsed = Self.parse(marked)
        return Self.apply(SwiftAddExplicitType.edits(in: parsed.text, caret: parsed.caret), to: parsed.text)
    }

    func testAddsTheTypeASelfDescribingValueHas() {
        XCTAssertEqual(addType("func f() { let ‸name = \"a\" }\n"), "func f() { let name: String = \"a\" }\n")
        XCTAssertEqual(addType("func f() { let ‸ok = true }\n"), "func f() { let ok: Bool = true }\n")
        XCTAssertEqual(addType("func f() { let ‸xs = [\"a\", \"b\"] }\n"), "func f() { let xs: [String] = [\"a\", \"b\"] }\n")
        XCTAssertEqual(addType("func f() { let ‸m = [\"a\": true] }\n"), "func f() { let m: [String: Bool] = [\"a\": true] }\n")
        XCTAssertEqual(addType("struct Box<T> { var v: T }\nfunc f() { let ‸b = Box<Int>(v: 1) }\n"), "struct Box<T> { var v: T }\nfunc f() { let b: Box<Int> = Box<Int>(v: 1) }\n")
        XCTAssertEqual(addType("enum Outer { struct Inner {} }\nfunc f() { let ‸i = Outer.Inner() }\n"), "enum Outer { struct Inner {} }\nfunc f() { let i: Outer.Inner = Outer.Inner() }\n")
    }

    func testDoesNotGuessATypeTheCompilerInfers() {
        for source in [
            "func f() { let ‸n = 5 }\n",
            "func f() { let ‸d = compute() }\nfunc compute() -> Int { 1 }\n",
            "func f() { let ‸xs = [1, 2] }\n",
            "func f() { let ‸x: Int = 5 }\n",
            "func f() { let ‸e = [String]() }\n",
        ] {
            let parsed = Self.parse(source)
            XCTAssertNotNil(refusal(SwiftAddExplicitType.edits(in: parsed.text, caret: parsed.caret)), source)
        }
    }

    // MARK: - Move to extension

    private func move(_ marked: String) -> String? {
        let parsed = Self.parse(marked)
        return Self.apply(SwiftMoveToExtension.edits(in: parsed.text, caret: parsed.caret), to: parsed.text)
    }

    func testMovesAMethodWithItsCommentIntoAnExtension() {
        XCTAssertEqual(
            move("struct S {\n    var stored = 1\n\n    /// The answer.\n    func ‸f() -> Int { stored }\n    func g() {}\n}\n"),
            "struct S {\n    var stored = 1\n    func g() {}\n}\n\nextension S {\n    /// The answer.\n    func f() -> Int { stored }\n}\n"
        )
    }

    func testMovesFromANestedTypeToTheQualifiedName() {
        XCTAssertEqual(
            move("enum Outer {\n    struct Inner {\n        func ‸f() {}\n    }\n}\n"),
            "enum Outer {\n    struct Inner {\n    }\n}\n\nextension Outer.Inner {\n    func f() {}\n}\n"
        )
    }

    func testKeepsWhatAnExtensionCannotHold() {
        for source in [
            "struct S {\n    var ‸stored = 1\n}\n",
            "struct S {\n    lazy var ‸cached = 1\n}\n",
            "class C {\n    init() {}\n    ‸init(a: Int) {}\n}\n",
            "class B { func f() {} }\nclass C: B {\n    override func ‸f() {}\n}\n",
            "enum E {\n    case ‸a\n}\n",
            "struct G<T> {\n    static var ‸count = 0\n}\n",
            "protocol P {\n    func ‸f()\n}\n",
        ] {
            let parsed = Self.parse(source)
            XCTAssertNotNil(refusal(SwiftMoveToExtension.edits(in: parsed.text, caret: parsed.caret)), source)
        }
        XCTAssertNotNil(move("struct S {\n    static var ‸shared = 1\n}\n"))
        XCTAssertNotNil(move("struct S {\n    var ‸total: Int { 1 }\n}\n"))
        XCTAssertNotNil(move("struct S {\n    init() {}\n    ‸init(a: Int) {}\n}\n"))
        // The only initializer of a struct: leaving the body would bring back the memberwise one.
        let only = Self.parse("struct S {\n    var a: Int\n    ‸init(a: Int) { self.a = a }\n}\n")
        XCTAssertNotNil(refusal(SwiftMoveToExtension.edits(in: only.text, caret: only.caret)))
    }

    // MARK: - Change signature

    /// The byte range of every whole-word occurrence of `name` (declaration, calls, anything else that names it).
    static func occurrences(of name: String, in text: String) -> [Range<Int>] {
        let bytes = Array(text.utf8)
        let word = Array(name.utf8)
        func isWord(_ byte: UInt8) -> Bool { byte == 0x5F || (0x30 ... 0x39).contains(byte) || (0x41 ... 0x5A).contains(byte) || (0x61 ... 0x7A).contains(byte) }
        var result: [Range<Int>] = []
        var index = 0
        while index + word.count <= bytes.count {
            if Array(bytes[index ..< index + word.count]) == word,
               index == 0 || !isWord(bytes[index - 1]), index + word.count == bytes.count || !isWord(bytes[index + word.count]) {
                result.append(index ..< index + word.count)
                index += word.count
            } else {
                index += 1
            }
        }
        return result
    }

    /// The subject at `‸`, the change `transform` makes to its parameters, and the text with the edits applied to
    /// every occurrence of the function's name.
    private func changeSignature(
        _ marked: String, transform: (inout [SwiftSignatureParameter]) -> Void
    ) -> (text: String?, failure: String?, skipped: Int) {
        let parsed = Self.parse(marked)
        guard let subject = SwiftChangeSignature.subject(in: parsed.text, caret: parsed.caret) else { return (nil, "no subject", 0) }
        var change = SwiftSignatureChange(parameters: subject.parameters, oldShape: subject.shape)
        transform(&change.parameters)
        switch SwiftChangeSignature.edits(
            in: parsed.text, nameBytes: Self.occurrences(of: subject.name, in: parsed.text), primary: subject.nameBytes,
            oldCount: subject.parameterCount, change: change
        ) {
        case .failure(let failure): return (nil, failure.message, 0)
        case .success(let outcome): return (Self.apply(.success(outcome.edits), to: parsed.text), nil, outcome.skipped.count)
        }
    }

    func testTheSubjectIsTheFunctionAtTheCaretWithItsParametersAsCallsSeeThem() {
        let source = "struct S {\n    func run(_ a: Int, with b: String = \"x\", rest: Int...) {}\n}\n"
        let caret = source.utf8.distance(from: source.startIndex, to: source.range(of: "run")!.lowerBound) + 1
        let subject = SwiftChangeSignature.subject(in: source, caret: caret)
        XCTAssertEqual(subject?.name, "run")
        XCTAssertEqual(subject?.parameters.map(\.label), ["_", "with", "rest"])
        XCTAssertEqual(subject?.parameters.map(\.name), ["a", "b", "rest"])
        XCTAssertEqual(subject?.parameters.map(\.type), ["Int", "String", "Int..."])
        XCTAssertEqual(subject?.parameters.map(\.defaultValue), ["", "\"x\"", ""])
        XCTAssertEqual(subject?.shape, [.init(label: "_", hasDefault: false, isVariadic: false), .init(label: "with", hasDefault: true, isVariadic: false), .init(label: "rest", hasDefault: false, isVariadic: true)])
        XCTAssertNil(SwiftChangeSignature.subject(in: source, caret: 2))
    }

    func testReorderingParametersReordersTheArgumentsOfEveryCall() {
        let result = changeSignature("func ‸f(a: Int, b: String) {}\nfunc g() { f(a: 1, b: \"x\"); f(a: 2, b: \"y\") }\n") { $0.reverse() }
        XCTAssertEqual(result.text, "func f(b: String, a: Int) {}\nfunc g() { f(b: \"x\", a: 1); f(b: \"y\", a: 2) }\n")
        XCTAssertEqual(result.skipped, 0)
    }

    func testRelabelingChangesTheLabelAtDeclarationAndCalls() {
        let result = changeSignature("func ‸f(from a: Int, _ b: Int) {}\nfunc g() { f(from: 1, 2) }\n") {
            $0[0].label = "to"
            $0[1].label = "extra"
        }
        XCTAssertEqual(result.text, "func f(to a: Int, extra b: Int) {}\nfunc g() { f(to: 1, extra: 2) }\n")
        let unlabeled = changeSignature("func ‸f(a: Int) {}\nfunc g() { f(a: 1) }\n") { $0[0].label = "_" }
        XCTAssertEqual(unlabeled.text, "func f(_ a: Int) {}\nfunc g() { f(1) }\n")
    }

    func testRenamingTheParameterRenamesItThroughTheBody() {
        let result = changeSignature("func ‸f(_ a: Int) -> Int {\n    let b = a + 1\n    return a * b\n}\n") { $0[0].name = "value" }
        XCTAssertEqual(result.text, "func f(_ value: Int) -> Int {\n    let b = value + 1\n    return value * b\n}\n")
        // The label is kept when it differs from the name; when they become the same, one word is written.
        let same = changeSignature("func ‸f(value a: Int) {}\nfunc g() { f(value: 1) }\n") { $0[0].name = "value" }
        XCTAssertEqual(same.text, "func f(value: Int) {}\nfunc g() { f(value: 1) }\n")
    }

    func testRemovingAParameterDropsItsArgumentButNotWhenTheBodyReadsIt() {
        let result = changeSignature("func ‸f(a: Int, b: Int, c: Int) -> Int { a + c }\nfunc g() -> Int { f(a: 1, b: 2, c: 3) }\n") { $0.remove(at: 1) }
        XCTAssertEqual(result.text, "func f(a: Int, c: Int) -> Int { a + c }\nfunc g() -> Int { f(a: 1, c: 3) }\n")
        let used = changeSignature("func ‸f(a: Int, b: Int) -> Int { a + b }\n") { $0.removeLast() }
        XCTAssertNotNil(used.failure)
        XCTAssertTrue(used.failure?.contains("`b`") ?? false)
    }

    func testANewParameterGetsItsDefaultOrTheValueEveryCallPasses() {
        let withDefault = changeSignature("func ‸f(a: Int) {}\nfunc g() { f(a: 1) }\n") {
            $0.append(.init(label: "b", name: "b", type: "Int", defaultValue: "0"))
        }
        XCTAssertEqual(withDefault.text, "func f(a: Int, b: Int = 0) {}\nfunc g() { f(a: 1) }\n", "the default keeps the call valid")
        let withValue = changeSignature("func ‸f(a: Int) {}\nfunc g() { f(a: 1) }\n") {
            $0.insert(.init(label: "_", name: "scale", type: "Double", callSiteValue: "2.0"), at: 0)
        }
        XCTAssertEqual(withValue.text, "func f(_ scale: Double, a: Int) {}\nfunc g() { f(2.0, a: 1) }\n")
    }

    func testDefaultedAndVariadicParametersAreMatchedAndKept() {
        let defaulted = changeSignature("func ‸f(a: Int = 1, b: Int) {}\nfunc g() { f(b: 2); f(a: 3, b: 4) }\n") { $0.reverse() }
        XCTAssertEqual(defaulted.text, "func f(b: Int, a: Int = 1) {}\nfunc g() { f(b: 2); f(b: 4, a: 3) }\n")
        let variadic = changeSignature("func ‸f(_ xs: Int..., sep: String) {}\nfunc g() { f(1, 2, 3, sep: \",\") }\n") { $0.reverse() }
        XCTAssertEqual(variadic.text, "func f(sep: String, _ xs: Int...) {}\nfunc g() { f(sep: \",\", 1, 2, 3) }\n")
    }

    func testATrailingClosureMustStayLastAndItsLabelsFollow() {
        let source = "func ‸run(n: Int, body: () -> Void) {}\nfunc g() { run(n: 1) { } }\n"
        let relabeled = changeSignature(source) { $0[0].label = "count" }
        XCTAssertEqual(relabeled.text, "func run(count n: Int, body: () -> Void) {}\nfunc g() { run(count: 1) { } }\n")
        let added = changeSignature(source) { $0.insert(.init(label: "m", name: "m", type: "Int", callSiteValue: "7"), at: 1) }
        XCTAssertEqual(added.text, "func run(n: Int, m: Int, body: () -> Void) {}\nfunc g() { run(n: 1, m: 7) { } }\n")
        let moved = changeSignature(source) { $0.reverse() }
        XCTAssertNil(moved.text.flatMap { $0.contains("run(n: 1) { }") ? nil : $0 }, "the closure parameter moved: the call is left alone")
        XCTAssertEqual(moved.skipped, 1)
    }

    func testACallItCannotMatchIsLeftAndReported() {
        let result = changeSignature("func ‸f(a: Int, b: Int) {}\nfunc g() { f(a: 1); f(b: 2, a: 1) }\n") { $0.reverse() }
        XCTAssertEqual(result.text, "func f(b: Int, a: Int) {}\nfunc g() { f(a: 1); f(b: 2, a: 1) }\n", "`f(a: 1)` misses a required parameter, `f(b: 2, a: 1)` is already out of order")
        XCTAssertEqual(result.skipped, 2)
    }

    func testAListSpreadOverLinesStaysSpreadOverLines() {
        let source = "func ‸f(\n    a: Int,\n    b: Int\n) {}\nfunc g() {\n    f(\n        a: 1,\n        b: 2\n    )\n}\n"
        let result = changeSignature(source) { $0.reverse() }
        XCTAssertEqual(result.text, "func f(\n    b: Int,\n    a: Int\n) {}\nfunc g() {\n    f(\n        b: 2,\n        a: 1\n    )\n}\n")
    }

    func testAnOverrideKeepsItsOwnInternalNames() {
        let source = "protocol P {\n    func ‸f(_ a: Int, _ b: Int)\n}\nstruct S: P {\n    func f(_ x: Int, _ y: Int) { print(x, y) }\n}\n"
        let result = changeSignature(source) { $0.reverse() }
        XCTAssertEqual(result.text, "protocol P {\n    func f(_ b: Int, _ a: Int)\n}\nstruct S: P {\n    func f(_ y: Int, _ x: Int) { print(x, y) }\n}\n")
    }

    func testNonsenseLists() {
        func problem(_ edit: (inout [SwiftSignatureParameter]) -> Void) -> String? {
            var parameters = [SwiftSignatureParameter(oldIndex: 0, label: "a", name: "a", type: "Int"), SwiftSignatureParameter(oldIndex: 1, label: "b", name: "b", type: "Int")]
            edit(&parameters)
            return SwiftChangeSignature.problem(in: SwiftSignatureChange(parameters: parameters), oldCount: 2)
        }
        XCTAssertNil(problem { _ in })
        XCTAssertNotNil(problem { $0[1].label = "a" }, "two labels")
        XCTAssertNotNil(problem { $0[1].name = "a" }, "two names")
        XCTAssertNotNil(problem { $0[0].name = "class" }, "a keyword")
        XCTAssertNotNil(problem { $0[0].name = "1x" })
        XCTAssertNotNil(problem { $0.append(.init(label: "c", name: "c", type: "Int")) }, "new, no default and no call-site value")
        XCTAssertNotNil(problem { $0.append(.init(label: "c", name: "c", type: "  ", defaultValue: "1")) }, "new, no type")
        XCTAssertNotNil(problem { $0[1].oldIndex = 0 }, "the same old parameter twice")
        XCTAssertNil(problem { $0.append(.init(label: "_", name: "c", type: "Int", defaultValue: "1")) })
        XCTAssertNil(problem { $0[0].label = "in" }, "`in` is a fine label")
    }

    func testTheChangeTravelsAsJSON() throws {
        let change = SwiftSignatureChange(parameters: [.init(oldIndex: 1, label: "_", name: "x", type: "Int", defaultValue: "3", callSiteValue: "")])
        XCTAssertEqual(SwiftSignatureChange(json: change.json)?.parameters, change.parameters)
        XCTAssertNil(SwiftSignatureChange(json: "nonsense"))
        XCTAssertNil(SwiftSignatureChange(json: nil))
    }

    // MARK: - Optional binding shorthand

    private func shorthand(_ marked: String, allowed: Bool = true) -> String? {
        let parsed = Self.parse(marked)
        return Self.apply(SwiftOptionalBindingShorthand.edits(in: parsed.text, caret: parsed.caret, allowsShorthand: allowed), to: parsed.text)
    }

    func testOptionalBindingsShortenAndExpand() {
        XCTAssertEqual(shorthand("func f(x: Int?) {\n    if let ‸x = x { print(x) }\n}\n"), "func f(x: Int?) {\n    if let x { print(x) }\n}\n")
        XCTAssertEqual(shorthand("func f(x: Int?) {\n    guard var ‸x = x else { return }\n    x += 1\n}\n"), "func f(x: Int?) {\n    guard var x else { return }\n    x += 1\n}\n")
        XCTAssertEqual(shorthand("func f(x: Int?, y: Int?) {\n    if let a = y, let ‸x = x { print(a, x) }\n}\n"), "func f(x: Int?, y: Int?) {\n    if let a = y, let x { print(a, x) }\n}\n")
        XCTAssertEqual(shorthand("func f(x: Int?) {\n    if let ‸x { print(x) }\n}\n"), "func f(x: Int?) {\n    if let x = x { print(x) }\n}\n")
        XCTAssertEqual(shorthand("func f(x: Int?) {\n    while let ‸x { print(x); return }\n}\n"), "func f(x: Int?) {\n    while let x = x { print(x); return }\n}\n")
    }

    func testOptionalBindingsThatAreNotTheSameNameOrCarryATypeStay() {
        for source in [
            "func f(x: Int?) {\n    if let ‸y = x { print(y) }\n}\n",
            "func f(x: Int?) {\n    if let ‸x: Int = x { print(x) }\n}\n",
            "func f(x: Int?) {\n    if let ‸x = x.map({ $0 }) { print(x) }\n}\n",
            "func f(x: Int?) {\n    if let (a, b) = ‸x { print(a, b) }\n}\n",
        ] {
            let parsed = Self.parse(source)
            XCTAssertNotNil(refusal(SwiftOptionalBindingShorthand.edits(in: parsed.text, caret: parsed.caret)), source)
        }
        // A package from before Swift 5.7 cannot use the short form, but can write it out.
        XCTAssertNil(shorthand("func f(x: Int?) {\n    if let ‸x = x { print(x) }\n}\n", allowed: false))
        XCTAssertNotNil(shorthand("func f(x: Int?) {\n    if let ‸x { print(x) }\n}\n", allowed: false))
    }

    func testTheToolsVersionIsReadFromTheManifestsFirstLine() {
        XCTAssertEqual(SwiftToolsVersion.parse(manifest: "// swift-tools-version: 5.9\nimport PackageDescription\n"), SwiftToolsVersion(major: 5, minor: 9))
        XCTAssertEqual(SwiftToolsVersion.parse(manifest: "// swift-tools-version:5.6.1\n"), SwiftToolsVersion(major: 5, minor: 6))
        XCTAssertEqual(SwiftToolsVersion.parse(manifest: "// swift-tools-version:6\n"), SwiftToolsVersion(major: 6, minor: 0))
        XCTAssertNil(SwiftToolsVersion.parse(manifest: "import PackageDescription\n"))
        XCTAssertTrue(SwiftToolsVersion(major: 5, minor: 9) > SwiftToolsVersion(major: 5, minor: 7))
        XCTAssertTrue(SwiftToolsVersion.allowsOptionalBindingShorthand(forFileAt: URL(fileURLWithPath: "/nowhere/at/all/A.swift")), "no manifest: allowed")
    }

    // MARK: - Syntax errors

    func testNothingIsRewrittenInAFileThatDoesNotParse() {
        let broken = "func f(a: Int) {\n    let x = a +\n    let y = ⟦a * 2⟧\n}\nfunc g( {\n"
        let parsed = Self.parse(broken)
        XCTAssertNotNil(refusal(SwiftIntroduceVariable.edits(in: parsed.text, selection: parsed.selection!, name: "x")))
        XCTAssertNotNil(refusal(SwiftInlineVariable.edits(in: parsed.text, caret: 0)))
        XCTAssertNil(SwiftConditionalConversion.available(in: parsed.text, caret: 0))
    }
}
