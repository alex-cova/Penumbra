import JavaIntelligence
import XCTest
@testable import Umbra

@MainActor
final class IDEExternalLibrariesModelTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ext-libs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// A jar with `org/x/Foo.class`, `org/x/Foo$1.class` and `META-INF/MANIFEST.MF`.
    private func makeJar(named name: String) throws -> URL {
        let content = scratch.appendingPathComponent("content-\(name)", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: content.appendingPathComponent("org/x"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: content.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        for path in ["org/x/Foo.class", "org/x/Foo$1.class", "META-INF/MANIFEST.MF"] {
            try Data("x".utf8).write(to: content.appendingPathComponent(path))
        }
        let jar = scratch.appendingPathComponent(name)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = content
        zip.arguments = ["-qr", jar.path, "."]
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        return jar
    }

    private func waitForRows(
        _ model: IDEExternalLibrariesModel, filter: String = "", until condition: ([IDEExternalLibraryItem]) -> Bool
    ) async throws -> [IDEExternalLibraryItem] {
        for _ in 0..<100 {
            let rows = model.rows(filter: filter)
            if condition(rows) { return rows }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return model.rows(filter: filter)
    }

    func testNoLibrariesAndNoJDKHasNoSection() {
        let model = IDEExternalLibrariesModel()
        XCTAssertTrue(model.rows().isEmpty)
        XCTAssertTrue(model.isEmpty)
    }

    func testSectionStartsCollapsed() throws {
        let model = IDEExternalLibrariesModel()
        model.update(libraries: [JavaExternalLibrary(jar: try makeJar(named: "a.jar"))])
        XCTAssertEqual(model.rows().map(\.kind), [.section])
        model.toggle(IDEExternalLibrariesModel.sectionID)
        XCTAssertEqual(model.rows().map(\.kind), [.section, .library])
    }

    func testExpandingALibraryReadsItsPackagesAndSkipsInnerClasses() async throws {
        let jar = try makeJar(named: "a.jar")
        let library = JavaExternalLibrary(jar: jar)
        let model = IDEExternalLibrariesModel()
        model.update(libraries: [library])
        model.expand(IDEExternalLibrariesModel.sectionID)
        model.expand(library.id)
        let rows = try await waitForRows(model) { $0.contains { $0.kind == .package } }
        XCTAssertEqual(rows.map(\.title), ["External Libraries", "a.jar", "META-INF", "org.x"])

        let package = try XCTUnwrap(rows.last)
        model.expand(package.id)
        let opened = model.rows()
        XCTAssertEqual(opened.map(\.title), ["External Libraries", "a.jar", "META-INF", "org.x", "Foo"])
        let type = try XCTUnwrap(opened.last)
        XCTAssertEqual(type.kind, .type)
        XCTAssertEqual(type.qualifiedName, "org.x.Foo")
        XCTAssertTrue(type.isOpenable)
        XCTAssertEqual(type.depth, 3)
    }

    func testResourceRowCarriesItsJarAndEntry() async throws {
        let jar = try makeJar(named: "a.jar")
        let library = JavaExternalLibrary(jar: jar)
        let model = IDEExternalLibrariesModel()
        model.update(libraries: [library])
        model.expand(IDEExternalLibrariesModel.sectionID)
        model.expand(library.id)
        var rows = try await waitForRows(model) { $0.contains { $0.kind == .folder } }
        model.expand(try XCTUnwrap(rows.first { $0.kind == .folder }).id)
        rows = model.rows()
        let manifest = try XCTUnwrap(rows.first { $0.kind == .resource })
        XCTAssertEqual(manifest.entry, "META-INF/MANIFEST.MF")
        XCTAssertEqual(manifest.archive, library.jar)
    }

    func testFilterOnlySearchesWhatIsOpen() async throws {
        let first = JavaExternalLibrary(jar: try makeJar(named: "alpha.jar"))
        let second = JavaExternalLibrary(jar: try makeJar(named: "beta.jar"))
        let model = IDEExternalLibrariesModel()
        model.update(libraries: [first, second])
        XCTAssertEqual(model.rows(filter: "beta").map(\.title), ["External Libraries", "beta.jar"])
        XCTAssertTrue(model.rows(filter: "Foo").isEmpty, "nothing is loaded, so a class name finds nothing")

        model.expand(first.id)
        _ = try await waitForRows(model) { $0.contains { $0.kind == .package } }
        model.expand(first.id + "\u{1F}pkg:org/x")
        let rows = model.rows(filter: "Foo")
        XCTAssertEqual(rows.map(\.title), ["External Libraries", "alpha.jar", "org.x", "Foo"])
    }

    func testReplacingLibrariesDropsStateOfRemovedOnes() async throws {
        let first = JavaExternalLibrary(jar: try makeJar(named: "alpha.jar"))
        let second = JavaExternalLibrary(jar: try makeJar(named: "beta.jar"))
        let model = IDEExternalLibrariesModel()
        model.update(libraries: [first, second])
        model.expand(first.id)
        model.selectedID = first.id
        model.update(libraries: [second])
        XCTAssertFalse(model.isExpanded(first.id))
        XCTAssertNil(model.selectedID)
        XCTAssertEqual(model.libraries.map(\.label), ["beta.jar"])
    }
}
