import Foundation
import SwiftIntelligence
import XCTest

/// The compile-rate gate for the native Swift refactorings (roadmap Phase 5): every case is compiled with
/// `swiftc -emit-sil` before the refactoring and after it, and both must succeed. A refactoring that changes
/// meaning (a hoisted expression that no longer type-checks, a moved member an extension cannot hold) fails
/// here even when its text looks right. Skipped without a toolchain.
final class SwiftRefactoringCompileTests: XCTestCase {
    private enum Kind {
        case introduce(String)
        case inline
        case convert
        case addType
        case move
        case shorthand
        case delete
        case extract(String)
        case signature(@Sendable (inout [SwiftSignatureParameter]) -> Void)
    }

    private static let cases: [(name: String, kind: Kind, source: String)] = [
        ("introduce operand", .introduce("product"), "func a1(a: Int, b: Int) -> Int {\n    let y = 1\n    return ⟦a * b⟧ + y\n}\n"),
        ("introduce implicit return", .introduce("doubled"), "func a2(a: Int) -> Int {\n    ⟦a * 2⟧ + 1\n}\n"),
        ("introduce in closure", .introduce("length"), "func a3(items: [String]) -> [Int] {\n    items.map { ⟦$0.count⟧ }\n}\n"),
        ("introduce under try", .introduce("n"), "func a4() throws -> Int {\n    return try ⟦compute4(1)⟧ + 1\n}\nfunc compute4(_ x: Int) throws -> Int { x }\n"),
        ("introduce under await", .introduce("n"), "func a5() async -> Int {\n    return await ⟦compute5(1)⟧ + 1\n}\nfunc compute5(_ x: Int) async -> Int { x }\n"),
        ("introduce in condition", .introduce("doubled"), "func a6(a: Int) {\n    if ⟦a * 2⟧ > 4 { print(a) }\n}\n"),
        ("introduce string", .introduce("greeting"), "func a7(name: String) {\n    print(⟦\"Hello, \" + name⟧)\n}\n"),
        ("introduce method call", .introduce("count"), "struct A8 { var items: [Int]; func total() -> Int { ⟦items.reduce(0, +)⟧ * 2 } }\n"),
        ("introduce in switch", .introduce("length"), "func a9(s: String, n: Int) -> Int {\n    switch n {\n    case 0: return ⟦s.count⟧ + 1\n    default: return n\n    }\n}\n"),
        ("introduce in guard", .introduce("length"), "func a10(s: String?) -> Int {\n    guard ⟦s?.count⟧ != nil else { return 0 }\n    return 1\n}\n"),
        ("introduce in void function", .introduce("doubled"), "func a11(a: Int) {\n    print(⟦a * 2⟧)\n}\n"),
        ("introduce in forEach", .introduce("doubled"), "func a12(items: [Int]) {\n    items.forEach { print(⟦$0 * 2⟧) }\n}\n"),
        ("introduce in getter", .introduce("base"), "struct A13 { var n = 1; var total: Int { ⟦n * 2⟧ + 1 } }\n"),
        ("inline sum", .inline, "func b1(a: Int, b: Int) -> Int {\n    let ‸sum = a + b\n    return sum * 2\n}\n"),
        ("inline count", .inline, "func b2(v: [Int]) -> Int {\n    let n = v.count\n    return ‸n + n\n}\n"),
        ("inline interpolation", .inline, "func b3(a: String, b: String) {\n    let full = a + b\n    print(\"\\(‸full)\")\n}\n"),
        ("inline call", .inline, "func b4() -> Int {\n    let ‸r = compute4b()\n    return r + 1\n}\nfunc compute4b() -> Int { 1 }\n"),
        ("inline member chain", .inline, "struct B5 { var name: String }\nfunc b5(p: B5) -> Int {\n    let ‸n = p.name\n    return n.count + n.utf8.count\n}\n"),
        ("inline literal", .inline, "func b6() -> Double {\n    let ‸rate = 2\n    return Double(rate) * 1.5\n}\n"),
        ("if to guard", .convert, "func c1(x: Int?) {\n    print(0)\n    ‸if let x = x {\n        print(x)\n        print(x + 1)\n    }\n}\n"),
        ("if to guard in loop", .convert, "func c2(xs: [Int?]) {\n    for x in xs {\n        ‸if let x = x {\n            print(x)\n        }\n    }\n}\n"),
        ("if to guard several", .convert, "func c3(a: Int?, b: String?) {\n    ‸if let a = a, let b = b, a > 0 {\n        print(a, b)\n    }\n}\n"),
        ("guard to if", .convert, "func c4(x: Int?) {\n    ‸guard let x = x else { return }\n    print(x)\n    print(x + 1)\n}\n"),
        ("guard to if in loop", .convert, "func c5(xs: [Int?]) {\n    for x in xs {\n        ‸guard let x = x else { continue }\n        print(x)\n    }\n}\n"),
        ("explicit string", .addType, "func d1() { let ‸name = \"a\"; print(name) }\n"),
        ("explicit array", .addType, "func d2() { let ‸xs = [\"a\", \"b\"]; print(xs) }\n"),
        ("explicit dictionary", .addType, "func d3() { let ‸m = [\"a\": true]; print(m) }\n"),
        ("explicit generic", .addType, "struct D4<T> { var v: T }\nfunc d4() { let ‸b = D4<Int>(v: 1); print(b) }\n"),
        ("explicit nested", .addType, "enum D5 { struct Inner {} }\nfunc d5() { let ‸i = D5.Inner(); print(i) }\n"),
        ("explicit property", .addType, "struct D6 { var ‸label = \"x\" }\n"),
        ("shorten if let", .shorthand, "func f1(x: Int?) {\n    if let ‸x = x { print(x) }\n}\n"),
        ("shorten guard var", .shorthand, "func f2(x: Int?) {\n    guard var ‸x = x else { return }\n    x += 1\n    print(x)\n}\n"),
        ("shorten self", .shorthand, "final class F3 {\n    func run() { let weak1 = { [weak self] in if let ‸self = self { print(self) } }; weak1() }\n}\n"),
        ("expand if let", .shorthand, "func f4(x: Int?) {\n    if let ‸x { print(x) }\n}\n"),
        ("expand while let", .shorthand, "func f5(x: Int?) {\n    while let ‸x { print(x); return }\n}\n"),
        ("signature reorder", .signature({ $0.reverse() }), "func ‸s1(a: Int, b: String) -> String { b + String(a) }\nfunc t1() -> String { s1(a: 1, b: \"x\") + s1(a: 2, b: \"y\") }\n"),
        ("signature relabel", .signature({ $0[0].label = "from"; $0[1].label = "_" }), "struct S2 {\n    func ‸s2(a: Int, b: Int) -> Int { a + b }\n    func t() -> Int { s2(a: 1, b: 2) + self.s2(a: 3, b: 4) }\n}\n"),
        ("signature add with call-site value", .signature({ $0.insert(.init(label: "scale", name: "scale", type: "Int", callSiteValue: "10"), at: 1) }), "func ‸s3(a: Int, b: Int) -> Int { a * b }\nfunc t3() -> Int { s3(a: 1, b: 2) }\n"),
        ("signature add with default", .signature({ $0.append(.init(label: "c", name: "c", type: "Int", defaultValue: "0")) }), "func ‸s4(a: Int) -> Int { a }\nfunc t4() -> Int { s4(a: 1) }\n"),
        ("signature remove unused", .signature({ $0.remove(at: 1) }), "func ‸s5(a: Int, unused: Int, b: Int = 2) -> Int { a + b }\nfunc t5() -> Int { s5(a: 1, unused: 9) + s5(a: 1, unused: 9, b: 3) }\n"),
        ("signature rename internal", .signature({ $0[0].name = "value" }), "func ‸s6(_ a: Int) -> Int {\n    let doubled = a * 2\n    return doubled + a\n}\nfunc t6() -> Int { s6(4) }\n"),
        ("signature protocol and conformer", .signature({ $0.reverse() }), "protocol P7 {\n    func ‸s7(_ a: Int, _ b: String) -> String\n}\nstruct C7: P7 {\n    func s7(_ x: Int, _ y: String) -> String { y + String(x) }\n}\nfunc t7(p: P7) -> String { p.s7(1, \"a\") + C7().s7(2, \"b\") }\n"),
        ("signature trailing closure", .signature({ $0.insert(.init(label: "times", name: "times", type: "Int", callSiteValue: "2"), at: 1) }), "func ‸s8(n: Int, body: () -> Void) { for _ in 0 ..< n { body() } }\nfunc t8() { s8(n: 1) { print(1) } }\n"),
        ("signature variadic", .signature({ $0.reverse() }), "func ‸s9(_ xs: Int..., sep: String) -> String { xs.map(String.init).joined(separator: sep) }\nfunc t9() -> String { s9(1, 2, 3, sep: \",\") }\n"),
        ("signature across lines", .signature({ $0.reverse() }), "func ‸s10(\n    a: Int,\n    b: Int\n) -> Int { a - b }\nfunc t10() -> Int {\n    s10(\n        a: 1,\n        b: 2\n    )\n}\n"),
        ("move method", .move, "struct E1 {\n    var stored = 1\n\n    /// The answer.\n    func ‸f() -> Int { stored }\n    func g() {}\n}\n"),
        ("move nested", .move, "enum E2 {\n    struct Inner {\n        func ‸f() {}\n    }\n}\n"),
        ("move computed", .move, "struct E3 {\n    var n = 1\n    var ‸double: Int { n * 2 }\n}\n"),
        ("move static", .move, "struct E4 {\n    static let ‸shared = E4()\n}\n"),
        ("move private use", .move, "struct E5 {\n    private var n = 1\n    func ‸bump() -> Int { n + 1 }\n}\n"),
        ("move convenience init", .move, "class E6 {\n    var n: Int\n    init(n: Int) { self.n = n }\n    ‸convenience init() { self.init(n: 0) }\n}\n"),
        ("move second initializer", .move, "struct E9 {\n    var a: Int\n    init(a: Int) { self.a = a }\n    ‸init() { self.init(a: 0) }\n}\n"),
        ("move subscript", .move, "struct E7 {\n    var items = [1, 2]\n    ‸subscript(i: Int) -> Int { items[i] }\n}\n"),
        ("move nested type", .move, "struct E8 {\n    ‸struct Helper {}\n    var n = 1\n}\n"),
        ("delete function with doc", .delete, "/// Does the thing.\nfunc ‸gone() {}\nfunc f() {}\n"),
        ("delete variable", .delete, "struct D {\n    var ‸gone = 1\n}\nfunc f() -> Int { 1 }\n"),
        ("delete type", .delete, "struct ‸Gone {}\nfunc f() {}\n"),
        ("extract expression with input", .extract("text"), "func e1(a: Int) -> String {\n    let y: Int = a + 1\n    return ⟦String(y)⟧\n}\n"),
        ("extract statements with output", .extract("counted"), "func e2(items: [Int]) -> Int {\n    ⟦let total: Int = items.count\n    print(total)⟧\n    return total\n}\n"),
        ("extract inout write", .extract("bump"), "func e3() {\n    var count = 0\n    ⟦count += 1\n    print(count)⟧\n}\n"),
        ("extract throwing", .extract("read"), "func e4() throws -> Int {\n    ⟦let n: Int = try compute()\n    print(n)⟧\n    return n\n}\nfunc compute() throws -> Int { 1 }\n"),
        ("extract async", .extract("loaded"), "func e5() async -> Int {\n    ⟦let n: Int = await fetch()\n    print(n)⟧\n    return n\n}\nfunc fetch() async -> Int { 1 }\n"),
        ("extract static member use", .extract("checked"), "struct E6 {\n    static var cache = [String: Int]()\n    static func lookup(_ key: String) -> Int {\n        ⟦let hit: Int = cache[key] ?? -1\n        print(hit)⟧\n        return hit\n    }\n}\n"),
        ("extract mutating", .extract("step"), "struct E7 {\n    var count = 0\n    mutating func bump() {\n        ⟦count += 1⟧\n    }\n}\n"),
        ("extract discarded call", .extract("log"), "func e9() {\n    ⟦print(\"hi\")⟧\n}\n"),
        ("extract plain statements", .extract("log"), "func e10() {\n    ⟦print(\"a\")\n    print(\"b\")⟧\n}\n"),
        ("extract parameter input", .extract("counted"), "func e11(items: [Int]) -> Int {\n    ⟦let n: Int = items.count\n    print(n)⟧\n    return n\n}\n"),
        ("extract inout parameter", .extract("bump"), "func e12(_ x: inout Int) {\n    ⟦x += 1\n    print(x)⟧\n}\n"),
        ("extract implicit return body", .extract("converted"), "struct P { var line: Int; var column: Int }\nstruct Q { init(line: Int, column: Int) {} }\nfunc e13(position: P) -> Q {\n    ⟦Q(line: position.line, column: position.column)⟧\n}\n"),
        ("extract output assigned inside", .extract("loaded"), "func e14(flag: Bool, text: String) -> String {\n    ⟦let index: Int\n    if flag {\n        index = 1\n    } else {\n        index = 2\n    }⟧\n    return String(text.prefix(index))\n}\n"),
        ("extract bare throw", .extract("fail"), "struct E15 {\n    var done = false\n    mutating func encode() throws {\n        ⟦throw EncodingError.failed⟧\n        done = true\n    }\n    enum EncodingError: Error { case failed }\n}\n"),
    ]

    func testEveryRefactoringLeavesCodeThatStillCompiles() throws {
        let oracle = try SwiftParityOracle.discover()
        // The gate has teeth: the oracle does flag a program that does not compile.
        XCTAssertFalse(try oracle.errors(in: "func broken() { let a: Int = \"s\" }\n", named: "Bad.swift").isEmpty)
        var failures: [String] = []
        var applied = 0
        for (name, kind, source) in Self.cases {
            let marked = SwiftRefactoringTests.parse(source)
            let result: SwiftRefactoringResult
            switch kind {
            case .introduce(let variable):
                guard let selection = marked.selection else { failures.append("\(name): no selection"); continue }
                result = SwiftIntroduceVariable.edits(in: marked.text, selection: selection, name: variable)
            case .inline: result = SwiftInlineVariable.edits(in: marked.text, caret: marked.caret)
            case .convert: result = SwiftConditionalConversion.edits(in: marked.text, caret: marked.caret)
            case .addType: result = SwiftAddExplicitType.edits(in: marked.text, caret: marked.caret)
            case .move: result = SwiftMoveToExtension.edits(in: marked.text, caret: marked.caret)
            case .shorthand: result = SwiftOptionalBindingShorthand.edits(in: marked.text, caret: marked.caret)
            case .delete: result = SwiftSafeDelete.edits(in: marked.text, caret: marked.caret)
            case .extract(let name):
                guard let selection = marked.selection else { failures.append("\(name): no selection"); continue }
                result = SwiftExtractMethod.edits(in: marked.text, selection: selection, name: name)
            case .signature(let transform):
                guard let subject = SwiftChangeSignature.subject(in: marked.text, caret: marked.caret) else {
                    failures.append("\(name): no function at the caret")
                    continue
                }
                var change = SwiftSignatureChange(parameters: subject.parameters, oldShape: subject.shape)
                transform(&change.parameters)
                switch SwiftChangeSignature.edits(
                    in: marked.text, nameBytes: SwiftRefactoringTests.occurrences(of: subject.name, in: marked.text),
                    primary: subject.nameBytes, oldCount: subject.parameterCount, change: change
                ) {
                case .success(let outcome):
                    if !outcome.skipped.isEmpty { failures.append("\(name): left \(outcome.skipped.count) calls unchanged") }
                    result = .success(outcome.edits)
                case .failure(let failure): result = .failure(failure)
                }
            }
            guard let after = SwiftRefactoringTests.apply(result, to: marked.text) else {
                if case .failure(let failure) = result { failures.append("\(name): refused: \(failure.message)") }
                continue
            }
            applied += 1
            let before = try oracle.errors(in: marked.text, named: "Before.swift")
            if !before.isEmpty { failures.append("\(name): the case does not compile to begin with: \(before.map(\.key))") }
            let errors = try oracle.errors(in: after, named: "After.swift")
            if !errors.isEmpty { failures.append("\(name): breaks the build \(errors.map { "\($0.key)@\($0.line)" }):\n\(after)") }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n---\n"))
        XCTAssertEqual(applied, Self.cases.count, "every case should apply")
    }
}
