import XCTest
@testable import JavaIntelligence

/// `JavaRoleIndexShardWriter/Reader`: the `roles.idx` round trip, role-mask filtering, and the
/// incremental rewrite (translated file ids, carried masks, orphan fallback).
final class JavaRoleIndexStoreTests: XCTestCase {
    private func temporaryShard() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("roles.idx")
    }

    private static func entry(_ path: String, stamp: Int64 = 1, roles: [String: JavaIdentifierRoles]) -> JavaRoleIndexEntry {
        JavaRoleIndexEntry(
            relativePath: path, stamp: JavaStamp(size: stamp, modificationDate: 0),
            roles: roles.mapValues { $0.rawValue }
        )
    }

    func testWriteReadFiltersByRoleMask() throws {
        let url = try temporaryShard()
        try JavaRoleIndexShardWriter().write([
            Self.entry("A.java", roles: ["run": [.call, .declared], "Box": [.typeName]]),
            Self.entry("B.java", roles: ["run": [.plain], "Box": [.call]]),
        ], to: url)

        let reader = try JavaRoleIndexShardReader(url: url)
        XCTAssertEqual(reader.relativePaths(containing: "run", roles: [.call, .member]), ["A.java"])
        XCTAssertEqual(reader.relativePaths(containing: "run", roles: [.plain]), ["B.java"])
        XCTAssertEqual(reader.relativePaths(containing: "run", roles: .all).sorted(), ["A.java", "B.java"])
        XCTAssertEqual(reader.relativePaths(containing: "Box", roles: [.call]), ["B.java"])
        XCTAssertEqual(reader.relativePaths(containing: "Box", roles: [.typeName]), ["A.java"])
        XCTAssertEqual(reader.relativePaths(containing: "missing", roles: .all), [])
        XCTAssertEqual(reader.relativePaths(containing: "run", roles: []), [])
        XCTAssertEqual(reader.files.map(\.relativePath), ["A.java", "B.java"])
    }

    func testRewriteTranslatesIDsAndCarriesMasks() throws {
        let url = try temporaryShard()
        try JavaRoleIndexShardWriter().write([
            Self.entry("A.java", stamp: 1, roles: ["run": [.call]]),
            Self.entry("B.java", stamp: 1, roles: ["run": [.plain]]),
            Self.entry("C.java", stamp: 1, roles: ["run": [.call]]),
        ], to: url)
        let existing = try JavaRoleIndexShardReader(url: url)

        // B.java edited (plain -> call), A.java deleted, D.java added.
        let rewritten = try JavaRoleIndexShardWriter().rewrite(
            from: existing, removing: [0],
            replacing: [Self.entry("B.java", stamp: 2, roles: ["run": [.call]]), Self.entry("D.java", stamp: 1, roles: ["run": [.imported]])],
            to: url
        )
        XCTAssertEqual(rewritten.relativePaths(containing: "run", roles: [.call]).sorted(), ["B.java", "C.java"])
        XCTAssertEqual(rewritten.relativePaths(containing: "run", roles: [.plain]), [])
        XCTAssertEqual(rewritten.relativePaths(containing: "run", roles: [.imported]), ["D.java"])
        XCTAssertEqual(rewritten.files.map(\.relativePath).sorted(), ["B.java", "C.java", "D.java"])
        XCTAssertEqual(
            try JavaRoleIndexShardReader(url: url).relativePaths(containing: "run", roles: [.call]).sorted(),
            ["B.java", "C.java"], "the rewritten bytes read back the same"
        )
    }

    func testRewriteKeepsUnrelatedIdentifiers() throws {
        let url = try temporaryShard()
        try JavaRoleIndexShardWriter().write([
            Self.entry("A.java", stamp: 1, roles: ["run": [.call], "Box": [.typeName]]),
            Self.entry("B.java", stamp: 1, roles: ["run": [.plain]]),
        ], to: url)
        let existing = try JavaRoleIndexShardReader(url: url)

        let rewritten = try JavaRoleIndexShardWriter().rewrite(
            from: existing, removing: [1],
            replacing: [Self.entry("B.java", stamp: 2, roles: ["run": [.call]])],
            to: url
        )
        XCTAssertEqual(rewritten.relativePaths(containing: "Box", roles: [.typeName]), ["A.java"])
        let entries = rewritten.allEntries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first(where: { $0.relativePath == "A.java" })?.roles["Box"], JavaIdentifierRoles.typeName.rawValue)
    }
}
