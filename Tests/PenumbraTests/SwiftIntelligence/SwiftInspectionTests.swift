import EditorIntelligence
import Foundation
import SwiftIntelligence
import XCTest

/// The native Swift inspections, one rule at a time: what it reports, what it must not, and for a fix the
/// exact text it leaves behind (which must still parse and no longer trigger the rule).
final class SwiftInspectionTests: XCTestCase {
    // MARK: - Helpers

    private func options(only rule: SwiftInspectionRule) -> SwiftInspectionOptions {
        var options = SwiftInspectionOptions()
        for other in SwiftInspectionRule.allCases where other != rule && other.isEnabledByDefault { options.disabled.insert(other.code) }
        if !rule.isEnabledByDefault { options.enabled.insert(rule.code) }
        return options
    }

    private func findings(_ rule: SwiftInspectionRule, _ text: String, limits: SwiftInspectionLimits = .standard) -> [SwiftInspection] {
        var options = options(only: rule)
        options.limits = limits
        return SwiftInspectionPipeline.analyze(text: text, options: options, cache: SwiftSyntaxParseCache(capacity: 1)).findings
    }

    private func apply(_ fix: SwiftInspectionFix, to text: String) -> String {
        var bytes = Array(text.utf8)
        for edit in fix.edits.sorted(by: { $0.bytes.lowerBound > $1.bytes.lowerBound }) {
            bytes.replaceSubrange(edit.bytes, with: Array(edit.replacement.utf8))
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// One finding of `rule` in `input`; its first fix turns `input` into `expected`, which parses cleanly
    /// and no longer has the finding.
    private func assertFix(
        _ rule: SwiftInspectionRule, _ input: String, becomes expected: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let found = findings(rule, input)
        XCTAssertEqual(found.count, 1, "\(rule.code) in:\n\(input)", file: file, line: line)
        guard let fix = found.first?.fixes.first else { return XCTFail("\(rule.code) offered no fix", file: file, line: line) }
        let result = apply(fix, to: input)
        XCTAssertEqual(result, expected, file: file, line: line)
        XCTAssertFalse(SwiftSyntaxDocument.parse(result).hasSyntaxErrors, "the fixed text does not parse:\n\(result)", file: file, line: line)
        XCTAssertTrue(findings(rule, result).isEmpty, "the fix leaves the finding in place:\n\(result)", file: file, line: line)
    }

    private func assertFlags(_ rule: SwiftInspectionRule, _ text: String, count: Int = 1, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(findings(rule, text).count, count, "\(rule.code) in:\n\(text)", file: file, line: line)
    }

    private func assertQuiet(_ rule: SwiftInspectionRule, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let found = findings(rule, text)
        XCTAssertTrue(found.isEmpty, "\(rule.code) should not report: \(found.map(\.message)) in:\n\(text)", file: file, line: line)
    }

    // MARK: - Probable bugs

    func testEmptyCatch() {
        assertFlags(.emptyCatch, "func f() { do { try g() } catch { } }")
        assertQuiet(.emptyCatch, "func f() { do { try g() } catch { print(error) } }")
        assertQuiet(.emptyCatch, "func f() {\n    do { try g() } catch {\n        // best effort\n    }\n}")
    }

    func testIdenticalOperands() {
        assertFlags(.identicalOperands, "func f(a: Bool) -> Bool { a && a }")
        assertFlags(.identicalOperands, "func f(a: Int) -> Bool { a < a }")
        assertFlags(.identicalOperands, "func f(a: Int) -> Int { a - a }")
        assertQuiet(.identicalOperands, "func f(a: Bool, b: Bool) -> Bool { a && b }")
        assertQuiet(.identicalOperands, "func f(x: Double) -> Bool { x != x }", )
        assertQuiet(.identicalOperands, "func f() -> Bool { next() && next() }")
    }

    func testDuplicateConditions() {
        assertFlags(.duplicateConditions, "func f(a: Int) { if a > 1 { } else if a < 0 { } else if a > 1 { } }")
        assertQuiet(.duplicateConditions, "func f(a: Int) { if a > 1 { } else if a < 0 { } else { } }")
        assertQuiet(.duplicateConditions, "func f() { if next() { } else if next() { } }")
        assertQuiet(.duplicateConditions, "func f(x: Int?) { if let a = x { } else if let a = x { } }")
    }

    func testDelegateNotWeak() {
        assertFlags(.delegateNotWeak, "class A { var delegate: Foo? }")
        assertFlags(.delegateNotWeak, "class A { var delegate: Foo! }")
        assertQuiet(.delegateNotWeak, "class A { var previewDelegate: Foo? }") // a helper the class owns
        assertQuiet(.delegateNotWeak, "class A { weak var delegate: Foo? }")
        assertQuiet(.delegateNotWeak, "class A { unowned var delegate: Foo }")
        assertQuiet(.delegateNotWeak, "struct A { var delegate: Foo? }")
        assertQuiet(.delegateNotWeak, "class A { var delegate: Foo }")
        assertQuiet(.delegateNotWeak, "class A { var delegate: ((Int) -> Void)? }")
        assertQuiet(.delegateNotWeak, "class A { static var delegate: Foo? }")
        assertQuiet(.delegateNotWeak, "class A { func f() { var delegate: Foo? = nil; _ = delegate } }")
    }

    func testForceOperators() {
        assertFlags(.forceUnwrap, "func f(x: Int?) -> Int { x! }")
        assertQuiet(.forceUnwrap, "func f(x: Int?) -> Bool { x != nil }")
        assertFlags(.forceTry, "func f() { try! g() }")
        assertQuiet(.forceTry, "func f() { try? g() }")
        assertFlags(.forceCast, "func f(x: Any) -> Int { x as! Int }")
        assertQuiet(.forceCast, "func f(x: Any) -> Int? { x as? Int }")
        let found = findings(.forceCast, "func f(x: Any) -> Int { x as! Int }")
        XCTAssertEqual(found.first.map { String(decoding: Array("func f(x: Any) -> Int { x as! Int }".utf8)[$0.bytes], as: UTF8.self) }, "as!")
    }

    // MARK: - Redundant code

    func testRedundantReturn() {
        assertFix(.redundantReturn, "func f() -> Int { return 1 }", becomes: "func f() -> Int { 1 }")
        assertFix(.redundantReturn, "var x: Int { return 1 }", becomes: "var x: Int { 1 }")
        assertFix(.redundantReturn, "let f = { (a: Int) in return a }", becomes: "let f = { (a: Int) in a }")
        assertFix(.redundantReturn, "var x: Int { get { return 1 } }", becomes: "var x: Int { get { 1 } }")
        assertQuiet(.redundantReturn, "func f() -> Int { let a = 1; return a }")
        assertQuiet(.redundantReturn, "func f() { return }")
        assertQuiet(.redundantReturn, "func f(a: Bool) -> Int { if a { return 1 }; return 2 }")
        assertFix(.redundantReturn, "func f(a: Bool) -> Int { return a ? 1 : 2 }", becomes: "func f(a: Bool) -> Int { a ? 1 : 2 }")
        assertQuiet(.redundantReturn, "func f(a: Bool) -> Int { return if a { 1 } else { 2 } }")
    }

    func testRedundantParentheses() {
        assertFix(.redundantParentheses, "func f(x: Bool) { if (x) { } }", becomes: "func f(x: Bool) { if x { } }")
        assertFix(.redundantParentheses, "func f(x: Int) { while (x > 0) { } }", becomes: "func f(x: Int) { while x > 0 { } }")
        assertFix(.redundantParentheses, "func f(x: Int?) { guard (x != nil) else { return } }", becomes: "func f(x: Int?) { guard x != nil else { return } }")
        assertQuiet(.redundantParentheses, "func f(x: Bool, y: Bool) { if (x) || y { } }")
        assertQuiet(.redundantParentheses, "func f(x: [Int]) { if (x.contains { $0 > 1 }) { } }")
        assertQuiet(.redundantParentheses, "func f(a: Int, b: Int) { switch (a, b) { default: break } }")
    }

    /// `x ?? nil` is how a double optional is flattened (`[K: V?]` subscripts, `group.next()`), so it is not
    /// redundant and no rule reports it. The review of this repository's code found only that use.
    func testNilCoalescingWithNilIsNotReported() {
        let text = "func f(table: [Int: Int?], k: Int) -> Int? { table[k] ?? nil }"
        let found = SwiftInspectionPipeline.analyze(text: text, options: SwiftInspectionOptions(enabled: Set(SwiftInspectionRule.allCases.map(\.code)))).findings
        XCTAssertFalse(found.contains { String(decoding: Array(text.utf8)[$0.bytes], as: UTF8.self).contains("??") })
    }

    func testRedundantOptionalInitialization() {
        assertFix(.redundantOptionalInitialization, "struct A { var x: Int? = nil }", becomes: "struct A { var x: Int? }")
        assertFix(.redundantOptionalInitialization, "func f() { var x: Int? = nil; x = 1 }", becomes: "func f() { var x: Int?; x = 1 }")
        assertQuiet(.redundantOptionalInitialization, "struct A { let x: Int? = nil }")
        assertQuiet(.redundantOptionalInitialization, "struct A { var x: Int? = 1 }")
        assertQuiet(.redundantOptionalInitialization, "struct A { @Published var x: Int? = nil }")
        assertQuiet(.redundantOptionalInitialization, "class A { lazy var x: Int? = nil }")
        assertQuiet(.redundantOptionalInitialization, "struct A { var x: Int = 0 }")
    }

    func testRedundantVoidReturn() {
        assertFix(.redundantVoidReturn, "func f() -> Void { }", becomes: "func f() { }")
        assertFix(.redundantVoidReturn, "func f() -> () { }", becomes: "func f() { }")
        assertFix(.redundantVoidReturn, "func f() async throws -> Void { }", becomes: "func f() async throws { }")
        assertQuiet(.redundantVoidReturn, "func f() -> Int { 1 }")
        assertQuiet(.redundantVoidReturn, "func f(g: () -> Void) { }")
        assertQuiet(.redundantVoidReturn, "func f() -> (Int, Int) { (1, 2) }")
    }

    func testUnneededBreak() {
        assertFix(
            .unneededBreak,
            "func f(x: Int) {\n    switch x {\n    case 1:\n        print(x)\n        break\n    default:\n        break\n    }\n}",
            becomes: "func f(x: Int) {\n    switch x {\n    case 1:\n        print(x)\n    default:\n        break\n    }\n}"
        )
        assertQuiet(.unneededBreak, "func f(x: Int) { switch x { case 1: break; default: break } }")
        assertQuiet(.unneededBreak, "func f(x: Int) { switch x { case 1: if x > 0 { break }; print(x); default: break } }")
    }

    func testUnusedClosureParameter() {
        assertFix(.unusedClosureParameter, "let f = { a, b in a }", becomes: "let f = { a, _ in a }")
        assertFix(.unusedClosureParameter, "let f = { (a: Int) in 1 }", becomes: "let f = { (_: Int) in 1 }")
        assertFlags(.unusedClosureParameter, "let f = { a, b in 1 }", count: 2)
        assertQuiet(.unusedClosureParameter, "let f = { a in a + 1 }")
        assertQuiet(.unusedClosureParameter, "let f = { _ in 1 }")
        assertQuiet(.unusedClosureParameter, "let f = { a in \"\\(a)\" }")
        assertQuiet(.unusedClosureParameter, "let f = { a in { a } }")
        assertQuiet(.unusedClosureParameter, "let f = { $0 + 1 }")
    }

    func testEmptyStatementBody() {
        assertFlags(.emptyStatementBody, "func f(x: Bool) { if x { } }")
        assertQuiet(.emptyStatementBody, "func f(x: AsyncStream<Int>) async { for await _ in x { } }")
        assertQuiet(.emptyStatementBody, "func f(it: inout IndexingIterator<[Int]>) { while it.next() != nil { } }")
        assertQuiet(.emptyStatementBody, "func f(x: Bool) { if x { } else { print(x) } }")
        assertQuiet(.emptyStatementBody, "func f(x: Bool) { if x { /* nothing to do */ } }")
        assertQuiet(.emptyStatementBody, "func f(x: Bool) { if x { print(x) } }")
    }

    func testExplicitInit() {
        assertFix(.explicitInit, "let a = Foo.init(1)", becomes: "let a = Foo(1)")
        assertFix(.explicitInit, "let a = Outer.Inner.init()", becomes: "let a = Outer.Inner()")
        assertQuiet(.explicitInit, "class A: B { override init() { super.init() } }")
        assertQuiet(.explicitInit, "struct A { init() { self.init(1) }; init(_ x: Int) {} }")
        assertQuiet(.explicitInit, "let make = Foo.init")
        assertQuiet(.explicitInit, "let a = foo.init(1)")
    }

    // MARK: - Idioms

    func testCountIsZero() {
        assertFix(.countIsZero, "func f(x: [Int]) -> Bool { x.count == 0 }", becomes: "func f(x: [Int]) -> Bool { x.isEmpty }")
        assertFix(.countIsZero, "func f(x: [Int]) -> Bool { x.count != 0 }", becomes: "func f(x: [Int]) -> Bool { !x.isEmpty }")
        assertFix(.countIsZero, "func f(x: [Int]) -> Bool { x.count > 0 }", becomes: "func f(x: [Int]) -> Bool { !x.isEmpty }")
        assertFix(.countIsZero, "func f(x: [Int]) -> Bool { 0 == x.count }", becomes: "func f(x: [Int]) -> Bool { x.isEmpty }")
        assertFix(.countIsZero, "func f(a: [Int], b: Bool) -> Bool { b && a.count == 0 }", becomes: "func f(a: [Int], b: Bool) -> Bool { b && a.isEmpty }")
        assertFix(.countIsZero, "func f(a: S) -> Bool { a.items.count == 0 }", becomes: "func f(a: S) -> Bool { a.items.isEmpty }")
        assertQuiet(.countIsZero, "func f(x: [Int]) -> Bool { x.count == 1 }")
        // A type of this file with a `count` and no `isEmpty` may be the one compared; `isEmpty` would not compile.
        assertQuiet(.countIsZero, "struct Buffer { var count: Int }\nfunc f(b: Buffer) -> Bool { b.count > 0 }")
        assertFlags(.countIsZero, "struct Buffer { var count: Int; var isEmpty: Bool { count == 0 } }\nfunc f(b: Buffer) -> Bool { b.count > 0 }")
        XCTAssertFalse(SwiftInspectionRule.countIsZero.isEnabledByDefault)
        assertQuiet(.countIsZero, "func f(x: [Int]?) -> Bool { x?.count == 0 }")
        assertQuiet(.countIsZero, "func f(x: [Int]) -> Bool { x.count < 0 }")
        // Precedence: the left operand of == is `a + b.count`, not `b.count`.
        assertQuiet(.countIsZero, "func f(a: Int, b: [Int]) -> Bool { a + b.count == 0 }")
    }

    func testFilterFirst() {
        assertFix(.filterFirst, "let a = xs.filter { $0 > 1 }.first", becomes: "let a = xs.first { $0 > 1 }")
        assertFix(.filterFirst, "let a = xs.filter({ $0 > 1 }).first", becomes: "let a = xs.first(where: { $0 > 1 })")
        assertQuiet(.filterFirst, "let a = xs.filter { $0 > 1 }.first(where: { $0 > 2 })")
        assertQuiet(.filterFirst, "let a = publisher.filter { $0 > 1 }.first()")
        assertQuiet(.filterFirst, "let a = xs.filter { $0 > 1 }.count")
        // `last(where:)` is not on every sequence, so the report has no fix.
        let last = findings(.filterFirst, "let a = xs.filter { $0 > 1 }.last")
        XCTAssertEqual(last.count, 1)
        XCTAssertTrue(last.first?.fixes.isEmpty ?? false)
    }

    func testSortedFirst() {
        assertFix(.sortedFirst, "let a = xs.sorted().first", becomes: "let a = xs.min()")
        assertFix(.sortedFirst, "let a = xs.sorted().last", becomes: "let a = xs.max()")
        assertQuiet(.sortedFirst, "let a = xs.sorted(by: >).first")
        assertQuiet(.sortedFirst, "let a = xs.sorted { $0 > $1 }.first")
        assertQuiet(.sortedFirst, "let a = xs.sorted().first(where: { $0 > 1 })")
    }

    func testFirstWhereNil() {
        assertFix(.firstWhereNil, "let a = xs.first(where: { $0 > 1 }) != nil", becomes: "let a = xs.contains(where: { $0 > 1 })")
        assertFix(.firstWhereNil, "let a = xs.first(where: { $0 > 1 }) == nil", becomes: "let a = !xs.contains(where: { $0 > 1 })")
        assertFix(.firstWhereNil, "let a = xs.first { $0 > 1 } != nil", becomes: "let a = xs.contains { $0 > 1 }")
        assertQuiet(.firstWhereNil, "let a = xs.first != nil")
        assertQuiet(.firstWhereNil, "let a = xs.first(where: { $0 > 1 }) != 3")
    }

    func testLeftoverPrint() {
        assertFlags(.leftoverPrint, "func f() { print(1) }")
        assertFlags(.leftoverPrint, "func f() { debugPrint(1); dump(1) }", count: 2)
        assertQuiet(.leftoverPrint, "func f() { logger.print(1) }")
        assertQuiet(.leftoverPrint, "func f() { printer(1) }")
    }

    // MARK: - Naming

    func testTypeNameCase() {
        assertFlags(.typeNameCase, "struct foo { }")
        assertFlags(.typeNameCase, "class widget { }; enum shape { }", count: 2)
        assertFlags(.typeNameCase, "typealias handler = () -> Void")
        assertQuiet(.typeNameCase, "struct Foo { }")
        assertQuiet(.typeNameCase, "struct _Foo { }")
        assertQuiet(.typeNameCase, "struct `foo` { }")
    }

    func testMemberNameCase() {
        assertFlags(.memberNameCase, "struct A { var Count = 0 }")
        assertFlags(.memberNameCase, "struct A { func DoThing() { } }")
        assertQuiet(.memberNameCase, "struct A { var count = 0; func doThing() { } }")
        assertQuiet(.memberNameCase, "struct A { static let URL = 1; static let MAX_COUNT = 2 }")
        assertQuiet(.memberNameCase, "struct A { var _Hidden = 0 }")
    }

    // MARK: - Metrics

    func testManyParameters() {
        let limits = SwiftInspectionLimits(parameters: 2)
        XCTAssertEqual(findings(.manyParameters, "func f(a: Int, b: Int, c: Int) { }", limits: limits).count, 1)
        XCTAssertEqual(findings(.manyParameters, "struct S { init(a: Int, b: Int, c: Int) { } }", limits: limits).count, 1)
        XCTAssertTrue(findings(.manyParameters, "func f(a: Int, b: Int) { }", limits: limits).isEmpty)
        XCTAssertTrue(findings(.manyParameters, "func f(a: Int, b: Int, c: Int) { }").isEmpty, "the default limit is 6")
    }

    func testLongFunction() {
        let limits = SwiftInspectionLimits(functionLines: 4)
        let long = "func f() {\n    a()\n    b()\n    c()\n    d()\n}\n"
        let short = "func f() {\n    a()\n}\n"
        XCTAssertEqual(findings(.longFunction, long, limits: limits).count, 1)
        XCTAssertTrue(findings(.longFunction, short, limits: limits).isEmpty)
    }

    func testHighComplexity() {
        let limits = SwiftInspectionLimits(complexity: 3)
        let complex = "func f(a: Int, b: Bool) -> Int {\n    if a > 0 && b { return 1 }\n    for _ in 0..<a { if b { return 2 } }\n    return a == 1 ? 3 : 4\n}"
        let simple = "func f(a: Int) -> Int {\n    if a > 0 { return 1 }\n    return 2\n}"
        let found = findings(.highComplexity, complex, limits: limits)
        XCTAssertEqual(found.count, 1)
        // 1 + `if` + `&&` + `for` + inner `if` + `?:`
        XCTAssertTrue(found.first?.message.contains("complexity of 6") ?? false, found.first?.message ?? "none")
        XCTAssertTrue(findings(.highComplexity, simple, limits: limits).isEmpty)
        // A nested function is its own function.
        let nested = "func outer() {\n    func inner(a: Int) { if a > 0 { } else if a < 0 { } else if a == 0 { } }\n}"
        XCTAssertEqual(findings(.highComplexity, nested, limits: limits).count, 1)
        XCTAssertTrue(findings(.highComplexity, nested, limits: limits).first?.message.contains("`inner`") ?? false)
    }

    // MARK: - Unused private declarations

    func testUnusedPrivateMember() {
        assertFlags(.unusedPrivateMember, "struct S {\n    private func helper() {}\n    func run() {}\n}\n")
        assertFlags(.unusedPrivateMember, "private let cache = 1\nfunc f() {}\n")
        assertFlags(.unusedPrivateMember, "final class C {\n    fileprivate var count2 = 0\n}\n")
        assertFlags(.unusedPrivateMember, "private struct Hidden {}\nfunc f() {}\n")
        assertFlags(.unusedPrivateMember, "private typealias Alias = Int\nfunc f() {}\n")
        assertFlags(.unusedPrivateMember, "@MainActor final class C {\n    private func helper() {}\n}\n")
        assertFlags(.unusedPrivateMember, "struct S {\n    private var a = 1, b = 2\n    func f() -> Int { a }\n}\n")
        let message = findings(.unusedPrivateMember, "struct S {\n    private func helper() {}\n}\n").first?.message
        XCTAssertEqual(message, "'helper' is private and nothing else in this file mentions it.")

        // Used in the file, by this or another type, or from an extension.
        assertQuiet(.unusedPrivateMember, "struct S {\n    private func helper() {}\n    func run() { helper() }\n}\n")
        assertQuiet(.unusedPrivateMember, "struct S {\n    private let id = 1\n}\nextension S {\n    func f() -> Int { id }\n}\n")
        assertQuiet(.unusedPrivateMember, "private let shared = 1\nfunc f() -> Int { shared }\n")
        assertQuiet(.unusedPrivateMember, "struct S {\n    private func h() {}\n    func f() { let g = { [self] in h() }; g() }\n}\n")
        assertQuiet(.unusedPrivateMember, "struct S {\n    private var token = 1\n    func f() -> String { \"\\(token)\" }\n}\n")
    }

    func testUnusedPrivateMemberSafeDelete() {
        assertFix(
            .unusedPrivateMember, "struct S {\n    private func helper() {}\n    func run() {}\n}\n",
            becomes: "struct S {\n    func run() {}\n}\n"
        )
        assertFix(.unusedPrivateMember, "private let cache = 1\nfunc f() {}\n", becomes: "func f() {}\n")
        assertFix(.unusedPrivateMember, "private struct Hidden {}\nfunc f() {}\n", becomes: "func f() {}\n")
        assertFix(.unusedPrivateMember, "private typealias Alias = Int\nfunc f() {}\n", becomes: "func f() {}\n")

        let found = findings(.unusedPrivateMember, "struct S {\n    private func helper() {}\n    func run() {}\n}\n")
        XCTAssertEqual(found.count, 1)
        let fix = found.first?.fixes.first
        XCTAssertEqual(fix?.title, "Safe delete 'helper'")
        XCTAssertEqual(fix?.isBatchable, false)
    }

    func testUnusedPrivateMemberSharedLinesAndSiblingBindingsKeepNoFix() {
        // One line holds the whole struct: deleting the line would delete code.
        let shared = findings(.unusedPrivateMember, "struct S { private func helper() {} }\n")
        XCTAssertEqual(shared.count, 1)
        XCTAssertTrue(shared.first?.fixes.isEmpty == true)
        // `b` is reported, but the declaration binds two names so it cannot go as a whole.
        let siblings = findings(.unusedPrivateMember, "struct S {\n    private var a = 1, b = 2\n    func f() -> Int { a }\n}\n")
        XCTAssertEqual(siblings.count, 1)
        XCTAssertEqual(siblings.first?.message, "'b' is private and nothing else in this file mentions it.")
        XCTAssertTrue(siblings.first?.fixes.isEmpty == true)
    }

    func testUnusedPrivateMemberLeavesWhatTheRuntimeOrAMacroMayReach() {
        for source in [
            "final class C {\n    @objc private func tapped() {}\n}\n",
            "final class C {\n    @IBOutlet private var label: UILabel!\n}\n",
            "struct S {\n    @State private var open = false\n}\n",
            "@Observable final class M {\n    private var value = 0\n}\n",
            "final class D: B {\n    override private func f() {}\n}\n",
            "struct S: Codable {\n    private enum CodingKeys: String, CodingKey { case a }\n    var a = 1\n}\n",
            "struct V: View {\n    private var body: some View { Text(\"\") }\n}\n",
            "protocol P {\n    func f()\n}\n",
            "struct S {\n    private(set) var value = 0\n}\n",
            "struct S {\n    var open: Int { 1 }\n    func f() {}\n}\n",
        ] {
            assertQuiet(.unusedPrivateMember, source)
        }
    }

    // MARK: - Options, suppression, broken code

    func testDefaultsAreOnForTheSafeRulesAndOffForTheOpinionatedOnes() {
        let enabled = SwiftInspectionOptions().enabledRules
        XCTAssertTrue(enabled.contains(.emptyCatch) && enabled.contains(.redundantReturn))
        for rule in [SwiftInspectionRule.forceUnwrap, .forceTry, .forceCast, .leftoverPrint, .countIsZero, .longFunction, .highComplexity, .manyParameters] {
            XCTAssertFalse(enabled.contains(rule), rule.code)
        }
        let options = SwiftInspectionOptions(disabled: ["count-is-zero"], enabled: ["force-try"])
        XCTAssertFalse(options.isEnabled(.countIsZero))
        XCTAssertTrue(options.isEnabled(.forceTry))
    }

    func testASeverityOverrideChangesWhatIsReported() {
        var options = options(only: .emptyCatch)
        options.severities["empty-catch"] = .error
        let found = SwiftInspectionPipeline.analyze(text: "func f() { do { try g() } catch { } }", options: options).findings
        XCTAssertEqual(found.first?.severity, .error)
    }

    func testAnUmbraCommentSilencesTheStatementBelowIt() {
        let text = """
        func f(x: Int?, y: Int?) {
            // umbra:disable force-unwrap
            let a = x!
            let b = y!
        }
        """
        let found = findings(.forceUnwrap, text)
        XCTAssertEqual(found.count, 1, "only `y!` is left")
        XCTAssertTrue(String(decoding: Array(text.utf8)[found[0].bytes], as: UTF8.self).hasPrefix("y"))

        let onTheFunction = """
        // umbra:disable force-unwrap, force-try
        func g(x: Int?) -> Int { x! }
        """
        XCTAssertTrue(findings(.forceUnwrap, onTheFunction).isEmpty)
        let all = "// umbra:disable all\nfunc g(x: Int?) -> Int { x! }"
        XCTAssertTrue(findings(.forceUnwrap, all).isEmpty)
        let other = "// umbra:disable force-try\nfunc g(x: Int?) -> Int { x! }"
        XCTAssertEqual(findings(.forceUnwrap, other).count, 1, "another rule's code does not silence this one")
    }

    func testSwiftLintCommentsAreHonouredForRulesThatHaveAnEquivalent() {
        let next = "func g(x: Int?) -> Int {\n    // swiftlint:disable:next force_unwrapping\n    return x!\n}"
        XCTAssertTrue(findings(.forceUnwrap, next).isEmpty)
        let this = "func g(x: Int?) -> Int {\n    return x! // swiftlint:disable:this force_unwrapping\n}"
        XCTAssertTrue(findings(.forceUnwrap, this).isEmpty)
        let region = "// swiftlint:disable force_unwrapping\nfunc g(x: Int?) -> Int { x! }\n// swiftlint:enable force_unwrapping\nfunc h(x: Int?) -> Int { x! }"
        let found = findings(.forceUnwrap, region)
        XCTAssertEqual(found.count, 1, "the region ends at the enable")
        XCTAssertGreaterThan(found[0].bytes.lowerBound, region.utf8.count - 20)
        let wrongName = "func g(x: Int?) -> Int {\n    // swiftlint:disable:next force_try\n    return x!\n}"
        XCTAssertEqual(findings(.forceUnwrap, wrongName).count, 1)
    }

    func testCodeWithASyntaxErrorOnlyLosesTheFindingsInTheBrokenStatement() {
        let text = """
        func good(x: [Int]) -> Bool { x.count == 0 }
        func broken(y: [Int]) -> Bool { y.count == 0 && (
        func alsoGood(z: [Int]) -> Bool { z.count == 0 }
        """
        let found = findings(.countIsZero, text)
        let names = found.map { String(decoding: Array(text.utf8)[$0.bytes], as: UTF8.self) }
        XCTAssertTrue(names.contains("x.count == 0"), "\(names)")
        XCTAssertFalse(names.contains("y.count == 0"), "a finding inside the broken function is dropped: \(names)")
        XCTAssertFalse(names.contains("z.count == 0"), "so is what the broken function's missing brace pulled in: \(names)")
    }

    func testFindingsAreInSourceOrderAndMapToEditorPositions() throws {
        let text = "func f(x: [Int], y: [Int]) -> Bool {\n    return y.count == 0 || x.count == 0\n}"
        let analysis = SwiftInspectionPipeline.analyze(text: text, options: options(only: .countIsZero))
        let counts = analysis.findings.filter { $0.id == "count-is-zero" }
        XCTAssertEqual(counts.count, 2)
        XCTAssertLessThan(counts[0].bytes.lowerBound, counts[1].bytes.lowerBound)
        let diagnostic = counts[0].asDiagnostic(map: analysis.map)
        XCTAssertEqual(diagnostic.source, "swift-inspection")
        XCTAssertEqual(diagnostic.code, "count-is-zero")
        XCTAssertEqual(diagnostic.range.start.line, 1)
        XCTAssertEqual(diagnostic.range.start.column, 11)
    }

    func testTheServiceReusesAnAnalysisOfTheSameTextAndOptions() {
        let counter = OptionsReads()
        let service = SwiftInspectionService(options: { counter.read(); return SwiftInspectionOptions() })
        let text = "func f(x: [Int]) -> Bool { x.count == 0 }"
        let first = service.analysis(of: text)
        let second = service.analysis(of: text)
        XCTAssertEqual(first.findings, second.findings)
        XCTAssertEqual(counter.count, 2, "the options are read on every call, so a change takes effect at once")
    }

    func testQuickFixesAtTheCaretIncludeTheRuleFixAndASuppression() async throws {
        let text = "func f(x: [Int]) -> Bool {\n    return x.count == 0\n}\n"
        let origin = TextPosition(line: 0, column: 0, utf16Offset: 0)
        let caret = TextPosition(line: 1, column: 15, utf16Offset: 0)
        let document = Document(
            url: URL(fileURLWithPath: "/tmp/Fix.swift"), displayName: "Fix.swift",
            contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: EditorIntelligence.TextRange(start: origin, end: origin)),
            cursor: Cursor(position: origin), viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: "swift"
        )
        let provider = SwiftCodeActionProvider(inspections: SwiftInspectionService(options: { [chosen = options(only: .countIsZero)] in chosen }))
        let actions = await provider.codeActions(for: document, at: caret, diagnostics: [])
        let titles = actions.map(\.title)
        XCTAssertTrue(titles.contains("Replace with 'isEmpty'"), "\(titles)")
        XCTAssertTrue(titles.contains("Suppress 'count-is-zero' for statement"), "\(titles)")
        let suppress = try XCTUnwrap(actions.first { $0.title.hasPrefix("Suppress") })
        XCTAssertEqual(suppress.edits.first?.replacement, "    // umbra:disable count-is-zero\n")
        XCTAssertEqual(suppress.edits.first?.range.start.line, 1)

        let away = await provider.codeActions(for: document, at: TextPosition(line: 0, column: 2, utf16Offset: 0), diagnostics: [])
        XCTAssertFalse(away.map(\.title).contains("Replace with 'isEmpty'"), "the caret is not on the finding")
    }
}

extension SwiftInspectionTests {
    func testTheMenuOffersFixAllForTheRuleAndTheCommandsToDisableOrConfigureIt() async throws {
        let text = "func a() -> Void { }\nfunc b() -> () { }\nfunc c() -> Int { 1 }\n"
        let origin = TextPosition(line: 0, column: 0, utf16Offset: 0)
        func document(_ text: String) -> Document {
            Document(
                url: URL(fileURLWithPath: "/tmp/Fix.swift"), displayName: "Fix.swift",
                contentSnapshot: TextSnapshot(version: 0, text: text),
                selection: Selection(range: EditorIntelligence.TextRange(start: origin, end: origin)),
                cursor: Cursor(position: origin), viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
                languageIdentifier: "swift"
            )
        }
        let provider = SwiftCodeActionProvider(inspections: SwiftInspectionService())
        let caret = TextPosition(line: 0, column: 12, utf16Offset: 12)
        let actions = await provider.codeActions(for: document(text), at: caret, diagnostics: [])
        let title = SwiftInspectionRule.redundantVoidReturn.title

        let fixAll = try XCTUnwrap(actions.first { $0.title == "Fix all '\(title)' problems in file" }, "\(actions.map(\.title))")
        XCTAssertEqual(fixAll.kind, "quickfix.fixAll")
        XCTAssertEqual(fixAll.edits.count, 2, "both functions, none of the third")
        let disable = try XCTUnwrap(actions.first { $0.title == "Disable inspection '\(title)'" })
        XCTAssertEqual(disable.command, CodeActionCommand(id: SwiftInspectionCommand.disable, arguments: ["redundant-void-return"]))
        let configure = try XCTUnwrap(actions.first { $0.title == "Edit inspection settings…" })
        XCTAssertEqual(configure.command?.id, SwiftInspectionCommand.configure)

        // One finding in the file: nothing to fix "all" of, but the commands stay.
        let single = await provider.codeActions(for: document("func a() -> Void { }\n"), at: caret, diagnostics: [])
        XCTAssertFalse(single.contains { $0.title.hasPrefix("Fix all") })
        XCTAssertTrue(single.contains { $0.title == "Edit inspection settings…" })
    }
}

private final class OptionsReads: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func read() { lock.withLock { value += 1 } }
}
