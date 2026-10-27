import XCTest
@testable import Umbra

final class IDELanguageServerRelevanceTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("umbra-lsp-rel-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testSourceKitIsRelevantWithPackageSwiftOrAnXcodeProject() throws {
        XCTAssertFalse(IDESourceKitServer.isRelevantToProject(root: root))
        try "import PackageDescription\n".write(
            to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8
        )
        XCTAssertTrue(IDESourceKitServer.isRelevantToProject(root: root))

        let xcodeOnly = FileManager.default.temporaryDirectory.appendingPathComponent("umbra-lsp-xc-\(UUID().uuidString)", isDirectory: true)
        let project = xcodeOnly.appendingPathComponent("App.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: xcodeOnly) }
        try "// !$*UTF8*$!\n{}\n".write(to: project.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
        XCTAssertTrue(IDESourceKitServer.isRelevantToProject(root: xcodeOnly), "an Xcode project gets the server too")
    }

    func testAPackageNeedsNoPreparationAndAFolderWithoutBothIsNeverStarted() async {
        try? "import PackageDescription\n".write(
            to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8
        )
        let ready = await IDESourceKitServer.prepare(root: root)
        XCTAssertEqual(ready, .ready, "SourceKit-LSP reads a package itself")
        XCTAssertNil(IDEXcodeIndexDatabase.initializationOptions(for: root), "a package gets no compilation database")
    }

    func testTypeScriptIsRelevantWithManifestOrConfig() {
        XCTAssertFalse(IDETypeScriptServer.isRelevantToProject(root: root))
        try? "{}".write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        XCTAssertTrue(IDETypeScriptServer.isRelevantToProject(root: root))
        try? FileManager.default.removeItem(at: root.appendingPathComponent("package.json"))
        try? "{}".write(to: root.appendingPathComponent("tsconfig.json"), atomically: true, encoding: .utf8)
        XCTAssertTrue(IDETypeScriptServer.isRelevantToProject(root: root))
    }

    func testTypeScriptLaunchIgnoresGlobalBinaryWithoutAProjectMarker() {
        let launch = IDETypeScriptServer.launch(root: root)
        XCTAssertNil(launch, "a global typescript-language-server must not start for a plain folder")
    }
}
