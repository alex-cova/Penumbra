import XCTest
@testable import TypeScriptIntelligence

/// F09: a file change updates the TypeScript index by that file's contribution only. The
/// guarantee that matters is that an index patched through any sequence of changes answers exactly
/// like one built from scratch over the final files.
final class TypeScriptIndexIncrementalTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ts-incremental-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func write(_ name: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func remove(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.removeItem(at: url)
        return url
    }

    // MARK: - Comparing two indexes

    /// Everything the index answers about the project, in a form that ignores iteration order.
    private struct Snapshot: Equatable {
        var symbols: [String: Set<String>]
        var exports: [String: Set<String>]
        var uses: [String: Set<String>]
        var fileCount: Int
    }

    private let queries = ["", "A", "Al", "Gam", "use", "run", "Be", "x", "Thing"]
    private let usedNames = ["Alpha", "Gamma", "Beta", "helper", "Thing", "useAlpha"]

    private func snapshot(_ index: TypeScriptIndex) async -> Snapshot {
        var symbols: [String: Set<String>] = [:]
        var exports: [String: Set<String>] = [:]
        for query in queries {
            let found = await index.symbols(matching: query, limit: 10_000)
            symbols[query] = Set(found.map { "\($0.name)|\($0.container)|\($0.url.lastPathComponent)|\($0.kind)|\($0.nameBytes)" })
            let exported = await index.exports(matching: query, limit: 10_000)
            exports[query] = Set(exported.map { "\($0.name)|\($0.url.lastPathComponent)|\($0.kind)|\($0.signature)|\($0.isTypeOnly)" })
        }
        var uses: [String: Set<String>] = [:]
        for name in usedNames {
            for definer in ["a.ts", "d.ts", "e.ts"] {
                let result = await index.externalUses(of: [name], definingFile: root.appendingPathComponent(definer))
                uses["\(name)@\(definer)"] = Set(result.map { "\($0.url.lastPathComponent)|\($0.ranges)" })
            }
        }
        return Snapshot(symbols: symbols, exports: exports, uses: uses, fileCount: await index.fileCount)
    }

    private func freshSnapshot() async -> Snapshot {
        let fresh = TypeScriptIndex()
        await fresh.setRoot(root)
        return await snapshot(fresh)
    }

    private func assertAgreesWithAFreshIndex(
        _ index: TypeScriptIndex, _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let patched = await snapshot(index)
        let rebuilt = await freshSnapshot()
        XCTAssertEqual(patched.fileCount, rebuilt.fileCount, message, file: file, line: line)
        for query in queries {
            XCTAssertEqual(patched.symbols[query], rebuilt.symbols[query], "\(message): symbols for `\(query)`", file: file, line: line)
            XCTAssertEqual(patched.exports[query], rebuilt.exports[query], "\(message): exports for `\(query)`", file: file, line: line)
        }
        for (key, value) in rebuilt.uses {
            XCTAssertEqual(patched.uses[key], value, "\(message): external uses \(key)", file: file, line: line)
        }
    }

    // MARK: - Tests

    private func seed() throws {
        try write("a.ts", "export class Alpha { run(): void {} }\nexport const helper = 1;")
        try write("b.ts", "import { Alpha } from './a';\nexport function useAlpha() { return new Alpha(); }")
        try write("c.ts", "export { Alpha as Beta } from './a';")
        try write("sub/d.ts", "export interface Thing { x: number }")
    }

    func testAnEditedFileReplacesItsOwnContribution() async throws {
        try seed()
        let index = TypeScriptIndex()
        await index.setRoot(root)
        await assertAgreesWithAFreshIndex(index, "freshly built")

        // The exported class is renamed: its old name must leave every table, the new one enter.
        let a = try write("a.ts", "export class Gamma { run(): void {} }\nexport const helper = 1;")
        await index.applyFileChanges([a])
        await assertAgreesWithAFreshIndex(index, "after renaming Alpha to Gamma")
        // `useAlpha` still matches the query at a word start; what must be gone is `Alpha` itself.
        let stale = await index.exports(matching: "Alpha", limit: 100).filter { $0.name == "Alpha" }
        XCTAssertTrue(stale.isEmpty, "the old export is gone: \(stale)")
        let renamed = await index.exports(matching: "Gamma", limit: 100)
        XCTAssertEqual(renamed.map(\.name), ["Gamma"])
    }

    func testAddingAndRemovingFiles() async throws {
        try seed()
        let index = TypeScriptIndex()
        await index.setRoot(root)

        let e = try write("e.ts", "export class Thing2 {}\nexport function helper2() {}")
        await index.applyFileChanges([e])
        await assertAgreesWithAFreshIndex(index, "after adding e.ts")
        let added = await index.contains(e)
        XCTAssertTrue(added)

        let removed = try remove("sub/d.ts")
        await index.applyFileChanges([removed])
        await assertAgreesWithAFreshIndex(index, "after removing sub/d.ts")
        let gone = await index.exports(matching: "Thing", limit: 100)
        XCTAssertEqual(gone.map(\.name), ["Thing2"], "Thing left with its file; Thing2 stayed")
    }

    func testReExportsAndImportersFollowTheDefiningFile() async throws {
        try seed()
        let index = TypeScriptIndex()
        await index.setRoot(root)
        // The re-export now points at something else, and b stops importing.
        let c = try write("c.ts", "export { helper as Beta } from './a';")
        let b = try write("b.ts", "export function useAlpha() { return 1; }")
        await index.applyFileChanges([c, b])
        await assertAgreesWithAFreshIndex(index, "after rewriting c.ts and b.ts")
    }

    func testAChangeListWithRepeatsAndMissingFilesSettlesToTheFinalState() async throws {
        try seed()
        let index = TypeScriptIndex()
        await index.setRoot(root)
        let a = try write("a.ts", "export class Alpha2 {}")
        _ = try write("a.ts", "export class Alpha3 { x = 1 }")
        let ghost = root.appendingPathComponent("never-existed.ts")
        let notSource = try write("readme.md", "# nope")
        await index.applyFileChanges([a, ghost, a, notSource])
        await assertAgreesWithAFreshIndex(index, "after a messy change list")
    }

    /// A long run of mixed changes, checked against a fresh build every few steps.
    func testManyMixedChangesStayEquivalent() async throws {
        try seed()
        let index = TypeScriptIndex()
        await index.setRoot(root)
        var live: [String: String] = [:]
        for step in 0..<24 {
            let name = ["a.ts", "b.ts", "x/f1.ts", "x/f2.ts", "x/y/f3.ts"][step % 5]
            let url = root.appendingPathComponent(name)
            if step % 7 == 6, live[name] != nil || FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
                live[name] = nil
            } else {
                let text = "export class Alpha\(step % 3) { run\(step)(): void {} }\nexport const helper\(step % 4) = \(step);\n"
                    + "import { Thing } from './sub/d';\nexport function useAlpha\(step % 2)() { return new Alpha\(step % 3)(); }"
                try write(name, text)
                live[name] = text
            }
            await index.applyFileChanges([url])
            if step % 6 == 5 { await assertAgreesWithAFreshIndex(index, "after step \(step)") }
        }
        await assertAgreesWithAFreshIndex(index, "after the last step")
    }
}
