import Foundation
import XCTest
@testable import JavaIntelligence

final class ZipArchiveCacheTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("zip-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSecondLookupReusesTheOpenedArchive() throws {
        let jar = try copyOfFixtureJar(named: "a.jar")
        let cache = ZipArchiveCache(capacity: 2)
        let first = try XCTUnwrap(cache.archive(at: jar))
        let second = try XCTUnwrap(cache.archive(at: jar))
        XCTAssertTrue(first === second)
        XCTAssertTrue(first.contains("com/penumbra/fixture/Fixture.class"))
    }

    func testAChangedFileIsOpenedAgain() throws {
        let jar = try copyOfFixtureJar(named: "a.jar")
        let cache = ZipArchiveCache(capacity: 2)
        let first = try XCTUnwrap(cache.archive(at: jar))
        // Same size, later date: only the modification date tells the two files apart.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: jar.path)
        let second = try XCTUnwrap(cache.archive(at: jar))
        XCTAssertFalse(first === second)
        XCTAssertEqual(cache.count, 1)
    }

    func testKeepsOnlyTheMostRecentlyUsedArchives() throws {
        let cache = ZipArchiveCache(capacity: 2)
        let jars = try ["a.jar", "b.jar", "c.jar"].map { try copyOfFixtureJar(named: $0) }
        let first = try XCTUnwrap(cache.archive(at: jars[0]))
        _ = cache.archive(at: jars[1])
        _ = cache.archive(at: jars[0])
        _ = cache.archive(at: jars[2])
        XCTAssertEqual(cache.count, 2)
        // `b.jar` was the least recently used: `a.jar` is still the archive handed out first.
        XCTAssertTrue(first === cache.archive(at: jars[0]))
    }

    func testMissingOrNonZipFilesAreNotKept() throws {
        let cache = ZipArchiveCache(capacity: 2)
        XCTAssertNil(cache.archive(at: directory.appendingPathComponent("missing.jar")))
        let junk = directory.appendingPathComponent("junk.jar")
        try Data([0, 1, 2, 3]).write(to: junk)
        XCTAssertNil(cache.archive(at: junk))
        XCTAssertEqual(cache.count, 0)
    }

    private func copyOfFixtureJar(named name: String) throws -> URL {
        let destination = directory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: JavaFixtures.jarURL, to: destination)
        return destination
    }
}
