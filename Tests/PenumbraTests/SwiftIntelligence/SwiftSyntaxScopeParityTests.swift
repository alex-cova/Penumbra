import Foundation
import SwiftIntelligence
import XCTest

/// swift-syntax's scope rules (`SwiftSyntaxScopes`, over `SwiftLexicalLookup`) against the hand-written
/// ones in `SwiftFileModel.bindings`, on the same text: for each identifier reference both can see, is
/// it the same local declaration, or in neither case a local at all?
///
/// This is the gate in `docs/SWIFT_INTELLIGENCE_ROADMAP.md` (Phase 3): `SwiftResolver` keeps using the
/// model's scopes until the two agree on real code. The small fixtures say what each rule should be;
/// the corpus run measures it on this repository's own Swift.
final class SwiftSyntaxScopeParityTests: XCTestCase {
    struct Row {
        var name: String
        var line: Int
        var treeSitter: Range<Int>?
        var swiftSyntax: SwiftSyntaxScopes.Resolution

        /// Both say not a local; both say the same declaration, or one of the equivalent ones a repeated
        /// pattern declares; or swift-syntax knows the name as implicit and tree-sitter has a binding for it.
        var agrees: Bool {
            switch (treeSitter, swiftSyntax) {
            case (nil, .outer): return true
            case (.some, .implicit): return true
            case (.some(let ts), .local(let declaration, let others)): return ts == declaration || others.contains(ts)
            default: return false
            }
        }
    }

    /// Every reference both parsers see, with the local declaration each resolves it to.
    private func compare(_ text: String) throws -> [Row] {
        let parsed = try XCTUnwrap(SwiftAnalysis.parse(text), "tree-sitter could not parse the text")
        let document = SwiftSyntaxDocument.parse(text)
        var lineStarts = [0]
        for (offset, byte) in text.utf8.enumerated() where byte == UInt8(ascii: "\n") { lineStarts.append(offset + 1) }
        var rows: [Row] = []
        for reference in SwiftSyntaxScopes.references(in: document) {
            guard let use = parsed.model.use(at: reference.bytes), case .value = use.role else { continue }
            let treeSitter = parsed.model.binding(named: reference.name, at: reference.bytes.lowerBound)?.nameBytes
            let line = lineStarts.lastIndex { $0 <= reference.bytes.lowerBound } ?? 0
            rows.append(Row(name: reference.name, line: line + 1, treeSitter: treeSitter, swiftSyntax: reference.resolution))
        }
        return rows
    }

    /// The text of the declaration `byte range` names, to say what a reference resolved to.
    private func spelling(_ range: Range<Int>?, in text: String) -> String {
        guard let range else { return "nil" }
        let bytes = Array(text.utf8)
        return String(decoding: bytes[range], as: UTF8.self) + "@\(range.lowerBound)"
    }

    private func spelling(_ resolution: SwiftSyntaxScopes.Resolution, in text: String) -> String {
        switch resolution {
        case .outer: return "outer"
        case .implicit: return "implicit"
        case .local(let declaration, let others): return spelling(declaration, in: text) + (others.isEmpty ? "" : " (+\(others.count))")
        }
    }

    private func assertAgrees(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let rows = try compare(text)
        XCTAssertFalse(rows.isEmpty, "the fixture compared nothing", file: file, line: line)
        for row in rows where !row.agrees {
            XCTFail(
                "line \(row.line) `\(row.name)`: tree-sitter \(spelling(row.treeSitter, in: text)), swift-syntax \(spelling(row.swiftSyntax, in: text))",
                file: file, line: line
            )
        }
    }

    // MARK: - Small fixtures: what each rule should say

    func testParametersAndLocals() throws {
        try assertAgrees("""
        func area(width: Int, height: Int) -> Int {
            let result = width * height
            return result
        }
        """)
    }

    func testAnInnerDeclarationShadowsAnOuterOne() throws {
        try assertAgrees("""
        func f(value: Int) -> Int {
            let x = value
            do {
                let x = x + 1
                return x
            }
        }
        """)
    }

    func testAParameterLabelIsNotTheLocalName() throws {
        try assertAgrees("""
        func move(from start: Int, to end: Int) -> Int {
            return end - start
        }
        """)
    }

    func testOptionalBindingsLiveInTheirOwnScope() throws {
        try assertAgrees("""
        func f(name: String?, other: Int?) {
            if let name {
                print(name)
            }
            guard let other else { return }
            print(other)
            if let count = other as Int?, count > 0 {
                print(count)
            }
        }
        """)
    }

    /// `if let x, other(x)`: the shorthand binding is visible to the clauses after it. The model once read
    /// the next clause as the binding's initializer (`if let x = other(x)`), so its scope began after that
    /// clause and a use in it resolved to the outer, still-optional variable.
    func testAShorthandBindingIsVisibleToTheNextClause() throws {
        try assertAgrees("""
        func f(owner: String?, count: Int?) {
            if let owner, !owner.isEmpty { print(owner) }
            guard let count, count > 0 else { return }
            print(count)
        }
        """)
        // Not just "some binding": the one `if let limit` declares, not the parameter. This is what rename,
        // find usages and an unused-variable check read.
        let text = """
        func f(limit: Int?) {
            if let limit, limit <= 0 { return }
        }
        """
        let rows = try compare(text)
        let uses = rows.filter { $0.name == "limit" }
        XCTAssertEqual(uses.count, 1)
        let bytes = Array(text.utf8)
        let ifLet = try XCTUnwrap(text.range(of: "if let limit")).upperBound
        let declared = text.utf8.distance(from: text.utf8.startIndex, to: ifLet) - "limit".utf8.count
        XCTAssertEqual(uses.first?.treeSitter, declared..<(declared + 5), "bytes: \(bytes.count)")
    }

    func testForLoopsAndClosures() throws {
        try assertAgrees("""
        func f(items: [Int]) -> Int {
            var total = 0
            for item in items {
                total += item
            }
            let doubled = items.map { value in value * 2 }
            let named = items.map { (n: Int) -> Int in n + total }
            return total + doubled.count + named.count
        }
        """)
    }

    func testSwitchPatternsAndCatch() throws {
        try assertAgrees("""
        enum Shape { case circle(Double), square(Double) }
        func f(shape: Shape) -> Double {
            switch shape {
            case .circle(let radius):
                return radius
            case .square(let side):
                return side * side
            }
        }
        func g() {
            do { try h() } catch {
                print(error)
            }
        }
        func h() throws {}
        """)
    }

    func testLocalFunctionsAndTypes() throws {
        try assertAgrees("""
        func outer(seed: Int) -> Int {
            func helper(_ n: Int) -> Int { n + seed }
            struct Box { var inner = 1 }
            return helper(Box().inner)
        }
        """)
    }

    func testMembersAndGlobalsAreNotLocals() throws {
        let rows = try compare("""
        let global = 1
        struct Counter {
            var count = 0
            mutating func bump() { count += global }
        }
        func f(value: Int) { print(value, global) }
        """)
        for name in ["count", "global"] {
            let found = rows.filter { $0.name == name }
            XCTAssertFalse(found.isEmpty, name)
            XCTAssertTrue(found.allSatisfy { $0.treeSitter == nil && $0.swiftSyntax == .outer }, "\(name) is not a local: \(found)")
        }
        XCTAssertTrue(rows.contains { $0.name == "value" && $0.swiftSyntax != .outer && $0.agrees })
    }

    // MARK: - The corpus: this repository's own Swift

    /// Every `.swift` file under the directories, relative to the repository root.
    private func swiftFiles(under directories: [String]) -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var files: [URL] = []
        for directory in directories {
            guard let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent(directory), includingPropertiesForKeys: nil) else { continue }
            files += enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        }
        return files.sorted { $0.path < $1.path }
    }

    func testScopeAgreementOnThisRepositorysSwift() throws {
        let files = swiftFiles(under: ["Sources/SwiftIntelligence", "Sources/EditorIntelligence", "Sources/EditorIntelligenceLSP"])
        XCTAssertGreaterThan(files.count, 50)
        var compared = 0
        var agreed = 0
        var disagreements: [String] = []
        var parseSeconds = 0.0
        var skipped = 0
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8), text.utf8.count < 400_000 else { skipped += 1; continue }
            let start = Date()
            let rows: [Row]
            do { rows = try compare(text) } catch { skipped += 1; continue }
            parseSeconds += Date().timeIntervalSince(start)
            compared += rows.count
            for row in rows {
                if row.agrees {
                    agreed += 1
                } else if disagreements.count < 40 {
                    disagreements.append("\(file.lastPathComponent):\(row.line) `\(row.name)` tree-sitter \(spelling(row.treeSitter, in: text)) / swift-syntax \(spelling(row.swiftSyntax, in: text))")
                }
            }
        }
        let rate = compared == 0 ? 0 : Double(agreed) / Double(compared)
        print("""
        SWIFT SCOPE PARITY: \(files.count) files (\(skipped) skipped), \(compared) references, \(agreed) agree = \(String(format: "%.2f", rate * 100))%, \
        both parsers and the comparison took \(String(format: "%.1f", parseSeconds)) s
        \(disagreements.joined(separator: "\n"))
        """)
        XCTAssertGreaterThan(compared, 1_000)
        XCTAssertEqual(agreed, compared, "the two scope rules disagree on:\n" + disagreements.joined(separator: "\n"))
    }
}
