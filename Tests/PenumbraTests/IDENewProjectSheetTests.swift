import AppKit
import SwiftUI
import XCTest
@testable import Umbra

/// The New Project sheet: its model, the "open this file afterwards" hand-off and a render of the
/// view. Set `UMBRA_VIEW_SNAPSHOTS` to a folder to keep the image.
@MainActor
final class IDENewProjectSheetTests: XCTestCase {
    private var directory: URL!
    private var workspace: IDEWorkspace!

    override func setUpWithError() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbra-newproject-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        workspace = IDEWorkspace()
        workspace.bootstrap()
    }

    override func tearDownWithError() throws {
        workspace.teardown()
        workspace = nil
        IDEWorkspace.isSessionPersistenceEnabled = true
        try? FileManager.default.removeItem(at: directory)
        for key in ["template", "organization", "location"] {
            UserDefaults.standard.removeObject(forKey: "umbra.newProject.\(key)")
        }
    }

    private func waitUntil(seconds: Double = 8, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    // MARK: Model

    func testCreateIsDisabledUntilThereIsALocationAndAValidName() {
        UserDefaults.standard.removeObject(forKey: "umbra.newProject.location")
        let model = IDENewProjectModel()
        model.parentDirectory = nil
        XCTAssertFalse(model.canCreate)
        XCTAssertTrue(model.issues.contains(.noLocation))

        model.parentDirectory = directory
        XCTAssertTrue(model.canCreate)

        model.name = "a/b"
        XCTAssertFalse(model.canCreate)
    }

    func testCreateWritesTheProjectAndRemembersTheChoices() async throws {
        let model = IDENewProjectModel()
        model.templateID = "swift.package.library"
        model.name = "Widgets"
        model.parentDirectory = directory
        model.organizationIdentifier = "org.acme"

        let created = await model.create()
        let root = try XCTUnwrap(created?.root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path))
        XCTAssertEqual(created?.template.primaryFile(for: created!.options), "Sources/Widgets/Widgets.swift")
        XCTAssertEqual(IDENewProjectDefaults.templateID, "swift.package.library")
        XCTAssertEqual(IDENewProjectDefaults.organizationIdentifier, "org.acme")
        XCTAssertEqual(IDENewProjectDefaults.location?.standardizedFileURL.path, directory.standardizedFileURL.path)

        // The same name again is refused, and says why.
        let again = await model.create()
        XCTAssertNil(again)
        XCTAssertFalse(model.canCreate)
    }

    func testThePreviewListsTheFilesOfTheSelectedTemplate() {
        let model = IDENewProjectModel()
        model.parentDirectory = directory
        model.name = "Demo"
        model.templateID = "swift.package.executable"
        XCTAssertEqual(
            model.previewPaths,
            [".gitignore", "Package.swift", "Sources/Demo/main.swift", "Tests/DemoTests/DemoTests.swift"]
        )
        XCTAssertEqual(
            model.previewRows.map(\.name),
            ["Sources", "Demo", "main.swift", "Tests", "DemoTests", "DemoTests.swift", ".gitignore", "Package.swift"]
        )
    }

    func testThePreviewTreeShowsFoldersBeforeTheirFiles() {
        let rows = IDENewProjectTree.rows(paths: [
            "App.xcodeproj/project.xcproj", ".gitignore", "App/ContentView.swift",
            "App/Assets.xcassets/Contents.json", "App/AppApp.swift",
        ])
        XCTAssertEqual(rows.map(\.path), [
            "App", "App/Assets.xcassets", "App/Assets.xcassets/Contents.json",
            "App/AppApp.swift", "App/ContentView.swift",
            "App.xcodeproj", "App.xcodeproj/project.xcproj", ".gitignore",
        ])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2, 1, 1, 0, 1, 0])
        XCTAssertEqual(rows.map(\.isDirectory), [true, true, false, false, false, true, false, false])
    }

    // MARK: Opening the new project

    func testTheRequestedFileOpensOnceAndOnlyForItsFolder() async throws {
        let template = try XCTUnwrap(IDEProjectTemplates.template(id: "swift.package.executable"))
        let options = IDENewProjectOptions(name: "Opens", parentDirectory: directory)
        let root = try IDEProjectWriter.create(template, options: options)
        let file = root.appendingPathComponent("Sources/Opens/main.swift")

        // A request for another folder is left alone.
        IDENewProjectOpenRequests.register(root: directory.appendingPathComponent("Other"), relativePath: "x.swift")
        IDENewProjectOpenRequests.register(root: root, relativePath: "Sources/Opens/main.swift")
        XCTAssertNil(IDENewProjectOpenRequests.take(for: directory.appendingPathComponent("Missing")))

        workspace.openProjectFolder(root)
        let opened = await waitUntil {
            self.workspace.workbench.activePane.selectedDocument?.url?.standardizedFileURL.path
                == file.standardizedFileURL.path
        }
        XCTAssertTrue(opened)
        XCTAssertNil(IDENewProjectOpenRequests.take(for: root), "the request is consumed")
        XCTAssertNotNil(IDENewProjectOpenRequests.take(for: directory.appendingPathComponent("Other")))
    }

    // MARK: View

    func testTheSheetRenders() throws {
        let model = IDENewProjectModel()
        _ = model
        UserDefaults.standard.removeObject(forKey: "umbra.newProject.location")
        let host = NSHostingView(
            rootView: IDENewProjectSheet().environment(workspace).preferredColorScheme(.dark)
        )
        // The sheet sizes itself: title, a 380-point body and the footer with its buttons.
        XCTAssertGreaterThan(host.fittingSize.height, 380 + 40)
        XCTAssertEqual(host.fittingSize.width, 780, accuracy: 1)
        host.frame = NSRect(x: 0, y: 0, width: 780, height: host.fittingSize.height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if let folder = ProcessInfo.processInfo.environment["UMBRA_VIEW_SNAPSHOTS"],
           let png = rep.representation(using: .png, properties: [:]) {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("new-project-sheet.png"))
        }
        // Not blank: more than one colour on the page.
        var colors = Set<UInt32>()
        for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                colors.insert(UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255))
            }
        }
        XCTAssertGreaterThan(colors.count, 4)
    }
}
