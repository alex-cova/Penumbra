import XCTest
@testable import JavaIntelligence

final class JavaIndexableRootTests: XCTestCase {
    func testCtSymReleaseLetterMapping() {
        XCTAssertEqual(CtSymRelease.letter(forFeatureVersion: 8), "8")
        XCTAssertEqual(CtSymRelease.letter(forFeatureVersion: 9), "9")
        XCTAssertEqual(CtSymRelease.letter(forFeatureVersion: 10), "A")
        XCTAssertEqual(CtSymRelease.letter(forFeatureVersion: 11), "B")
        XCTAssertEqual(CtSymRelease.letter(forFeatureVersion: 17), "H")
        XCTAssertEqual(CtSymRelease.letter(forFeatureVersion: 21), "L")
        XCTAssertEqual(CtSymRelease.letter(forFeatureVersion: 24), "O")
        XCTAssertNil(CtSymRelease.letter(forFeatureVersion: 7))
    }

    func testJarRootReadsFixtureJarAndDropsPrivateMembers() throws {
        let root = JarRoot(jarURL: JavaFixtures.jarURL)
        let stubs = try root.readStubs()
        let names = Set(stubs.map(\.qualifiedName))
        XCTAssertTrue(names.contains("com.penumbra.fixture.Fixture"))
        XCTAssertTrue(names.contains("com.penumbra.fixture.AbstractFixture"))
        XCTAssertTrue(names.contains("com.penumbra.fixture.Fixture.Point"))

        let fixture = try XCTUnwrap(stubs.first { $0.qualifiedName == "com.penumbra.fixture.Fixture" })
        XCTAssertNil(fixture.fields.first { $0.name == "name" }, "private field should be dropped for a library root")
        XCTAssertEqual(fixture.origin, .jar(JavaFixtures.jarURL))
    }

    func testJarRootStampMatchesFileAttributes() throws {
        let root = JarRoot(jarURL: JavaFixtures.jarURL)
        let expected = try XCTUnwrap(JavaStamp(url: JavaFixtures.jarURL))
        XCTAssertEqual(root.stamp, expected)
    }

    func testJarRootIDIsStableAndPathDerived() {
        let root = JarRoot(jarURL: JavaFixtures.jarURL)
        XCTAssertTrue(root.id.contains(JavaFixtures.jarURL.path))
    }

    func testJarRootOnMissingFileThrows() {
        let root = JarRoot(jarURL: URL(fileURLWithPath: "/does/not/exist.jar"))
        XCTAssertThrowsError(try root.readStubs())
    }

    // MARK: - JDK root choice

    private func makeJDKLayout(withJmods: Bool) throws -> JDKInstallation {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("jdk-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("lib"), withIntermediateDirectories: true)
        // A zip with no release directories, like the JDK 21 ct.sym that has none for release 21.
        try FileManager.default.copyItem(at: JavaFixtures.jarURL, to: home.appendingPathComponent("lib/ct.sym"))
        if withJmods {
            try FileManager.default.createDirectory(at: home.appendingPathComponent("jmods"), withIntermediateDirectories: true)
        }
        return JDKInstallation(home: home, featureVersion: 21, versionString: "21.0.1", vendor: nil)
    }

    func testJDKIndexRootFallsBackToJmodsWhenCtSymLacksTheRelease() throws {
        let installation = try makeJDKLayout(withJmods: true)
        defer { try? FileManager.default.removeItem(at: installation.home) }
        let choice = JDKIndexRoot.make(for: installation)
        XCTAssertEqual(choice.kind, "jmods")
        XCTAssertTrue(choice.root is JModsRoot)
    }

    func testJDKIndexRootKeepsCtSymWithoutJmods() throws {
        let installation = try makeJDKLayout(withJmods: false)
        defer { try? FileManager.default.removeItem(at: installation.home) }
        let choice = JDKIndexRoot.make(for: installation)
        XCTAssertEqual(choice.kind, "ctsym")
        XCTAssertTrue(choice.root is JDKCtSymRoot)
    }

    // MARK: - Real JDK (opt-in)

    func testEveryDiscoveredJDKIndexesJavaLang() throws {
        let installations = JDKLocator().discoverAll(additionalHomes: [])
        guard !installations.isEmpty else { throw XCTSkip("No JDK found on this machine") }
        for installation in installations {
            let stubs = try JDKIndexRoot.make(for: installation).root.readStubs()
            let names = Set(stubs.map(\.qualifiedName))
            XCTAssertTrue(names.contains("java.lang.String"), "JDK \(installation.versionString) lacks java.lang.String")
            XCTAssertTrue(names.contains("java.nio.charset.StandardCharsets"), "JDK \(installation.versionString)")
        }
    }

    func testJDKCtSymRootIndexesJavaLangString() throws {
        guard let found = TestJDK.discovered,
              let installation = ReleaseFileParser.parse(found.home),
              installation.hasCtSym else {
            throw XCTSkip("No JDK with ct.sym found on this machine")
        }
        let root = JDKCtSymRoot(installation: installation)
        let stubs = try root.readStubs()
        XCTAssertGreaterThan(stubs.count, 1000, "expected thousands of public JDK classes")
        let string = try XCTUnwrap(stubs.first { $0.qualifiedName == "java.lang.String" })
        XCTAssertTrue(string.methods.contains { $0.name == "length" })
        XCTAssertTrue(string.methods.contains { $0.name == "isBlank" })
        XCTAssertEqual(string.superclass?.erasedQualifiedName, "java.lang.Object")
        let arrayList = try XCTUnwrap(stubs.first { $0.qualifiedName == "java.util.ArrayList" })
        XCTAssertTrue(arrayList.interfaces.contains { $0.erasedQualifiedName == "java.util.List" })
    }
}
