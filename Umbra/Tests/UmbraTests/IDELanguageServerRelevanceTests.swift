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

    func testPythonIsRelevantWithManifestOrConfig() {
        XCTAssertFalse(IDEPythonServer.isRelevantToProject(root: root))
        try? "[project]\n".write(to: root.appendingPathComponent("pyproject.toml"), atomically: true, encoding: .utf8)
        XCTAssertTrue(IDEPythonServer.isRelevantToProject(root: root))
        try? FileManager.default.removeItem(at: root.appendingPathComponent("pyproject.toml"))
        try? "requests\n".write(to: root.appendingPathComponent("requirements.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(IDEPythonServer.isRelevantToProject(root: root))
        try? FileManager.default.removeItem(at: root.appendingPathComponent("requirements.txt"))
        try? "from setuptools import setup\n".write(to: root.appendingPathComponent("setup.py"), atomically: true, encoding: .utf8)
        XCTAssertTrue(IDEPythonServer.isRelevantToProject(root: root))
    }

    func testPythonLaunchIgnoresVenvWithoutAProjectMarker() throws {
        let bin = root.appendingPathComponent(".venv/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let server = bin.appendingPathComponent("pylsp")
        try "#!/bin/sh\nexit 0\n".write(to: server, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path)
        XCTAssertNil(IDEPythonServer.launch(root: root), "a virtualenv must not start the server for a plain folder")
    }

    func testPythonLaunchFindsVenvBinary() throws {
        try? "[project]\n".write(to: root.appendingPathComponent("pyproject.toml"), atomically: true, encoding: .utf8)
        let bin = root.appendingPathComponent(".venv/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let server = bin.appendingPathComponent("pylsp")
        try "#!/bin/sh\nexit 0\n".write(to: server, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path)
        XCTAssertEqual(IDEPythonServer.launch(root: root), server)
    }
}
