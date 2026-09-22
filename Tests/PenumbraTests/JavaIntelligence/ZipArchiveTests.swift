import XCTest
@testable import JavaIntelligence

final class ZipArchiveTests: XCTestCase {
    func testReadsAllExpectedEntriesFromFixtureJar() throws {
        let archive = try ZipArchive(url: JavaFixtures.jarURL)
        let names = Set(archive.entries.map(\.name))
        XCTAssertTrue(names.contains("com/penumbra/fixture/Fixture.class"))
        XCTAssertTrue(names.contains("com/penumbra/fixture/AbstractFixture.class"))
        XCTAssertTrue(names.contains("com/penumbra/fixture/Fixture$Point.class"))
        XCTAssertTrue(names.contains("META-INF/MANIFEST.MF"))
    }

    func testDecompressedEntryMatchesDirectlyReadClassFile() throws {
        let archive = try ZipArchive(url: JavaFixtures.jarURL)
        let fromZip = try archive.data(for: "com/penumbra/fixture/Fixture.class")
        let direct = JavaFixtures.classFile("Fixture")
        XCTAssertEqual(fromZip, direct)
    }

    func testManifestEntryDecompressesToPlausibleText() throws {
        let archive = try ZipArchive(url: JavaFixtures.jarURL)
        let manifest = try archive.data(for: "META-INF/MANIFEST.MF")
        let text = String(decoding: manifest, as: UTF8.self)
        XCTAssertTrue(text.contains("Manifest-Version"))
    }

    func testContainsReflectsPresenceOfEntries() throws {
        let archive = try ZipArchive(url: JavaFixtures.jarURL)
        XCTAssertTrue(archive.contains("com/penumbra/fixture/Fixture.class"))
        XCTAssertFalse(archive.contains("does/not/Exist.class"))
    }

    func testMissingEntryThrows() throws {
        let archive = try ZipArchive(url: JavaFixtures.jarURL)
        XCTAssertThrowsError(try archive.data(for: "nope.txt")) { error in
            guard case ZipArchiveError.entryNotFound = error else {
                return XCTFail("expected .entryNotFound, got \(error)")
            }
        }
    }

    func testNonZipDataThrows() {
        let junk = Data([0x00, 0x01, 0x02, 0x03])
        XCTAssertThrowsError(try ZipArchive(data: junk))
    }

    func testJDKCtSymOpensAndFindsJavaLangString() throws {
        guard let ctSym = TestJDK.discovered?.ctSym else {
            throw XCTSkip("No JDK with ct.sym found on this machine")
        }
        let archive = try ZipArchive(url: ctSym)
        let stringEntries = archive.entries.filter { $0.name.hasSuffix("java.base/java/lang/String.sig") }
        XCTAssertFalse(stringEntries.isEmpty, "expected at least one release's java/lang/String.sig in ct.sym")
    }
}
