import AppKit
import EditorIntelligence
import Penumbra
import XCTest
@testable import Umbra

/// A Swift interface SourceKit-LSP generated for an SDK symbol opens as a read-only tab with Swift
/// highlighting, like a decompiled Java class: the user reads it, Go to Definition lands in it, and
/// nothing edits or checks it.
@MainActor
final class IDEGeneratedInterfaceTests: XCTestCase {
    private var directory: URL!
    private var workspace: IDEWorkspace!

    override func setUp() async throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iface-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        workspace = IDEWorkspace()
        workspace.bootstrap()
    }

    override func tearDown() async throws {
        workspace?.teardown()
        IDEWorkspace.isSessionPersistenceEnabled = true
        try? FileManager.default.removeItem(at: directory)
    }

    private func open(_ relativePath: String, _ text: String) async throws -> (WorkbenchDocument, IDEEditorPaneHost) {
        let url = directory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        await workspace.openDocument(from: url)
        let document = try XCTUnwrap(workspace.workbench.activePane.selectedDocument)
        let host = workspace.host(for: workspace.workbench.activePaneID)
        let deadline = Date().addingTimeInterval(5)
        while host.textView.text != text, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(host.textView.text, text, "the editor never showed \(relativePath)")
        return (document, host)
    }

    func testAGeneratedInterfaceIsReadOnlyAndHighlightedAsSwift() async throws {
        let (document, host) = try await open(
            "sourcekit-lsp/GeneratedInterfaces/123/Swift.String.swiftinterface", "public struct String {}\n"
        )
        XCTAssertEqual(document.languageIdentifier, "swift")
        XCTAssertFalse(host.textView.isEditable, "an SDK interface is read, not edited")
    }

    func testAnOrdinarySwiftFileStaysEditable() async throws {
        let (document, host) = try await open("Sources/Lib/Box.swift", "public struct Box {}\n")
        XCTAssertEqual(document.languageIdentifier, "swift")
        XCTAssertTrue(host.textView.isEditable)
    }

    func testAProjectsOwnInterfaceFileIsNotMistakenForAGeneratedOne() async throws {
        let (_, host) = try await open("Sources/Lib/Lib.swiftinterface", "// swift-interface-format-version: 1.0\n")
        XCTAssertTrue(host.textView.isEditable, "only the folder SourceKit-LSP writes is read-only")
    }
}
