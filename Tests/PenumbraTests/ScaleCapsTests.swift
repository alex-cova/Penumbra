import EditorIntelligence
import Foundation
@testable import LanguageSyntax
import SwiftIntelligence
import TypeScriptIntelligence
import XCTest

/// F27: palette and completion lookups skip names that cannot match, without ever skipping one that
/// can; and the parse cache holds a few hundred open documents instead of thrashing at 64.
final class ScaleCapsTests: XCTestCase {
    // MARK: - NameSignature

    /// A small deterministic generator, so a failure is reproducible.
    private struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    func testTheSignatureNeverRejectsANameTheMatcherAccepts() {
        var random = Generator(state: 0xC0FFEE)
        // Mixed case, digits, separators, a few non-ASCII letters (the matcher folds only ASCII case).
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_$.éÉßΩж")
        func randomName() -> String {
            String((0..<Int.random(in: 1...14, using: &random)).map { _ in alphabet.randomElement(using: &random)! })
        }
        var matched = 0
        for _ in 0..<20_000 {
            let name = randomName()
            // Half the queries are a subsequence of the name (they usually match), half are unrelated.
            let query: String
            if Bool.random(using: &random) {
                query = String(name.filter { _ in Int.random(in: 0..<3, using: &random) != 0 })
            } else {
                query = randomName()
            }
            guard !query.isEmpty else { continue }
            if CompletionMatcher.matches(query, name) {
                matched += 1
                XCTAssertTrue(
                    NameSignature(name).couldMatch(NameSignature(query)),
                    "the signature rejected \(name) for \(query), which the matcher accepts"
                )
            }
        }
        XCTAssertGreaterThan(matched, 1_000, "the property was exercised on real matches")
    }

    func testTheSignatureRejectsNamesMissingACharacter() {
        let name = NameSignature("UserRepository")
        XCTAssertTrue(name.couldMatch(NameSignature("usrep")))
        XCTAssertTrue(name.couldMatch(NameSignature("UR")))
        XCTAssertFalse(name.couldMatch(NameSignature("Q")))
        XCTAssertFalse(name.couldMatch(NameSignature("user9")))
        XCTAssertTrue(name.couldMatch(NameSignature("")), "an empty query matches everything")
    }

    // MARK: - Index lookups against a brute-force reference

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scale-caps-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private func write(_ name: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private let typeNames = ["UserService", "UserRepository", "URLSession2", "HTTPClient", "parseJSON", "Base64Codec", "S3Client", "zeta", "Alpha"]
    private let queries = ["U", "Us", "UR", "UserS", "URL", "http", "HC", "json", "b6", "S3", "z", "al", "Q", "usr", "Xyz9", "A"]

    private func swiftSource(_ names: [String]) -> String {
        names.map { name in
            name.first!.isUppercase ? "public struct \(name) { public func run\(name)() {} }" : "public func \(name)() {}"
        }.joined(separator: "\n")
    }

    func testSwiftLookupsEqualTheMatcherOverEveryName() async throws {
        for (offset, name) in typeNames.enumerated() { try write("p\(offset % 3)/F\(offset).swift", swiftSource([name])) }
        let index = SwiftIndex()
        await index.setRoot(root)
        for query in queries {
            let symbols = await Set(index.symbols(matching: query, limit: .max).map(\.name))
            var expected = Set<String>()
            for name in typeNames + typeNames.filter({ $0.first!.isUppercase }).map({ "run\($0)" }) where CompletionMatcher.matches(query, name) {
                expected.insert(name)
            }
            XCTAssertEqual(symbols, expected, "symbols for \(query)")
            let exports = await Set(index.exports(matching: query, limit: .max).map(\.name))
            // Types and top-level functions are both exports.
            XCTAssertEqual(exports, Set(typeNames.filter { CompletionMatcher.matches(query, $0) }), "exports for \(query)")
        }
    }

    func testSwiftLookupsFollowEditsAndRemovals() async throws {
        let first = try write("A.swift", "public struct Widget {}")
        let index = SwiftIndex()
        await index.setRoot(root)
        var exports = await index.exports(matching: "Gad", limit: 10).map(\.name)
        XCTAssertEqual(exports, [])
        // A new type must be found by the next lookup, not by a scan built before it existed.
        let second = try write("B.swift", "public struct Gadget {}")
        await index.applyFileChanges([second])
        exports = await index.exports(matching: "Gad", limit: 10).map(\.name)
        XCTAssertEqual(exports, ["Gadget"])
        let symbols = await index.symbols(matching: "Gad", limit: 10).map(\.name)
        XCTAssertEqual(symbols, ["Gadget"])
        try FileManager.default.removeItem(at: second)
        await index.applyFileChanges([second])
        let gone = await index.exports(matching: "Gad", limit: 10).map(\.name)
        XCTAssertEqual(gone, [])
        let widget = await index.exports(matching: "Wid", limit: 10).map(\.name)
        XCTAssertEqual(widget, ["Widget"])
        _ = first
    }

    func testTypeScriptLookupsEqualTheMatcherAndFollowChanges() async throws {
        for (offset, name) in typeNames.enumerated() where name.first!.isUppercase {
            try write("p\(offset % 3)/f\(offset).ts", "export class \(name) { m\(name)(): void {} }")
        }
        let classes = typeNames.filter { $0.first!.isUppercase }
        let index = TypeScriptIndex()
        await index.setRoot(root)
        for query in queries {
            let exports = await Set(index.exports(matching: query, limit: .max).map(\.name))
            XCTAssertEqual(exports, Set(classes.filter { CompletionMatcher.matches(query, $0) }), "exports for \(query)")
            let symbols = await Set(index.symbols(matching: query, limit: .max).filter { classes.contains($0.name) }.map(\.name))
            XCTAssertEqual(symbols, Set(classes.filter { CompletionMatcher.matches(query, $0) }), "symbols for \(query)")
        }
        let added = try write("late.ts", "export class Latecomer {}")
        await index.applyFileChanges([added])
        let found = await index.exports(matching: "Lat", limit: 10).map(\.name)
        XCTAssertEqual(found, ["Latecomer"], "a name added after the scan was built is found")
        try FileManager.default.removeItem(at: added)
        await index.applyFileChanges([added])
        let removed = await index.exports(matching: "Lat", limit: 10).map(\.name)
        XCTAssertEqual(removed, [])
    }

    // MARK: - Parse cache

    private func parseCache(maxEntries: Int? = nil) -> DocumentParseCache {
        DocumentParseCache(languageIdentifier: "swift", language: SwiftAnalysis.language, maxEntries: maxEntries)
    }

    private func document(_ index: Int) -> Document {
        let text = "let value\(index) = \(index)\n"
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        return Document(
            url: URL(fileURLWithPath: "/tmp/scale-cache/file\(index).swift"), displayName: "file\(index).swift",
            contentSnapshot: TextSnapshot(version: 1, text: text),
            selection: Selection(range: TextRange(start: position, end: position)), cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100), languageIdentifier: "swift"
        )
    }

    func testTwoHundredOpenDocumentsAreParsedOnceByDefault() async {
        let cache = parseCache()
        for _ in 0..<3 { for index in 0..<200 { _ = await cache.tree(for: document(index)) } }
        let stats = await cache.statistics
        XCTAssertEqual(stats.fullParses, 200, "each document parsed once")
        XCTAssertEqual(stats.hits, 400, "the second and third passes are cache hits")
        XCTAssertEqual(stats.evictions, 0)
    }

    func testACapBelowTheOpenCountThrashesEveryPass() async {
        // A least-recently-used cache smaller than a cyclic working set misses every time: this is
        // what the old default of 64 did to 200 tabs, and the reason it is no longer the default.
        let cache = parseCache(maxEntries: 64)
        for _ in 0..<3 { for index in 0..<200 { _ = await cache.tree(for: document(index)) } }
        let stats = await cache.statistics
        XCTAssertEqual(stats.hits, 0)
        XCTAssertEqual(stats.fullParses, 600)
        XCTAssertGreaterThan(stats.evictions, 0)
    }

    func testTheByteCapStillBoundsTheCacheWhateverTheEntryCap() async {
        let cache = DocumentParseCache(languageIdentifier: "swift", language: SwiftAnalysis.language, maxEntries: 1_000, maxSourceBytes: 400)
        for index in 0..<50 { _ = await cache.tree(for: document(index)) }
        let bytes = await cache.cachedSourceBytes
        XCTAssertLessThanOrEqual(bytes, 400 + "let value49 = 49\n".utf8.count, "memory stays bounded by source bytes")
    }
}
