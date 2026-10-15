import AppKit
import Foundation
import Penumbra
import XCTest
@testable import Umbra

/// Idle autosave: one counter bump per edit, one sleeping task, a save only after real quiet.
@MainActor
final class IDEAutosaveControllerTests: XCTestCase {
    private func eventually(_ message: String = "condition never held", seconds: Double = 3, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), message)
    }

    private func makeController(delay: Duration = .milliseconds(120)) -> IDEAutosaveController {
        let controller = IDEAutosaveController()
        controller.settings = { .init(isEnabled: true, idleDelay: delay) }
        return controller
    }

    func testAnEditFollowedByQuietSaves() async {
        let controller = makeController()
        var saves = 0
        controller.save = { saves += 1 }

        controller.noteEdit()
        XCTAssertEqual(saves, 0, "it saved before the pause")

        await eventually { saves == 1 }
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(saves, 1, "it kept saving with nothing new typed")
    }

    func testTypingKeepsPushingTheSaveBack() async {
        let controller = makeController(delay: .milliseconds(200))
        var saves = 0
        controller.save = { saves += 1 }

        for _ in 0..<5 {
            controller.noteEdit()
            try? await Task.sleep(for: .milliseconds(80))
        }
        XCTAssertEqual(saves, 0, "it saved while typing went on")

        await eventually { saves == 1 }
        XCTAssertEqual(saves, 1)
    }

    func testAnotherEditAfterASaveStartsAnotherWait() async {
        let controller = makeController()
        var saves = 0
        controller.save = { saves += 1 }

        controller.noteEdit()
        await eventually { saves == 1 }
        try? await Task.sleep(for: .milliseconds(30))
        controller.noteEdit()
        await eventually { saves == 2 }
    }

    func testNothingHappensWhenItIsOff() async {
        let controller = IDEAutosaveController()
        controller.settings = { .init(isEnabled: false, idleDelay: .milliseconds(50)) }
        var saves = 0
        controller.save = { saves += 1 }

        controller.noteEdit()
        try? await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(saves, 0)
    }

    func testItWaitsAnotherPeriodWhileSavingWouldBeUnwelcome() async {
        let controller = makeController()
        var saves = 0
        var allowed = false
        controller.canSaveNow = { allowed }
        controller.save = { saves += 1 }

        controller.noteEdit()
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(saves, 0, "it saved during a composition")

        allowed = true
        await eventually { saves == 1 }
    }

    func testEditsDuringASaveGetTheirOwnPeriod() async {
        let controller = makeController()
        var saves = 0
        controller.save = { [unowned controller] in
            saves += 1
            if saves == 1 {
                // Typing arrives while the files are being written.
                try? await Task.sleep(for: .milliseconds(30))
                controller.noteEdit()
            }
        }

        controller.noteEdit()

        await eventually("the edit made during the save was never saved") { saves == 2 }
    }
}

@MainActor
final class IDEAutosaveWorkspaceTests: XCTestCase {
    private var directory: URL!
    private var workspace: IDEWorkspace!
    private var savedFocus = true

    override func setUp() async throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        savedFocus = IDEPreferences.shared.saveOnFocusLoss
        IDEPreferences.shared.saveOnFocusLoss = true
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("autosave-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        workspace = IDEWorkspace()
        workspace.bootstrap()
    }

    override func tearDown() async throws {
        workspace?.teardown()
        IDEPreferences.shared.saveOnFocusLoss = savedFocus
        IDEWorkspace.isSessionPersistenceEnabled = true
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ name: String, _ text: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func open(_ url: URL) async throws -> (WorkbenchDocument, IDEEditorPaneHost) {
        await workspace.openDocument(from: url)
        let document = try XCTUnwrap(workspace.workbench.activePane.selectedDocument)
        let host = workspace.host(for: workspace.workbench.activePaneID)
        await eventually("the editor never showed the file") { host.textView.text == (try? String(contentsOf: url, encoding: .utf8)) }
        try await Task.sleep(for: .milliseconds(200))
        return (document, host)
    }

    private func eventually(_ message: String = "condition never held", seconds: Double = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), message)
    }

    func testIdleAutosaveWritesTheFileAndKeepsTheBufferOpen() async throws {
        let url = try write("idle.txt", "old\n")
        let (document, host) = try await open(url)
        workspace.autosave.settings = { .init(isEnabled: true, idleDelay: .milliseconds(150)) }
        host.textView.text = "typed\n"
        document.isDirty = true

        workspace.autosave.noteEdit()

        await eventually("the idle save never happened") { (try? self.read(url)) == "typed\n" }
        await eventually { !document.isDirty }
        XCTAssertEqual(host.textView.text, "typed\n")
    }

    func testFocusLossSavesEveryUnsavedFile() async throws {
        let url = try write("focus.txt", "old\n")
        let (document, host) = try await open(url)
        host.textView.text = "edited\n"
        document.isDirty = true

        workspace.autosaveBecauseFocusMoved()

        await eventually("the focus-loss save never happened") { (try? self.read(url)) == "edited\n" }
    }

    func testFocusLossDoesNothingWhenTheSettingIsOff() async throws {
        IDEPreferences.shared.saveOnFocusLoss = false
        let url = try write("off.txt", "old\n")
        let (document, host) = try await open(url)
        host.textView.text = "edited\n"
        document.isDirty = true

        workspace.autosaveBecauseFocusMoved()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(try read(url), "old\n")
        XCTAssertTrue(document.isDirty)
    }

    func testAutosaveNeverOverwritesANewerFileAndNeverAsks() async throws {
        let url = try write("newer.txt", "base\n")
        let (document, host) = try await open(url)
        host.textView.text = "mine\n"
        document.isDirty = true
        try "theirs\n".write(to: url, atomically: true, encoding: .utf8)
        workspace.saveConflictResolver = { _ in
            XCTFail("an autosave must not ask")
            return .overwrite
        }

        await workspace.autosaveAll(reason: .autosaveIdle)

        XCTAssertEqual(try read(url), "theirs\n")
        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(workspace.externalChangeState(of: document), .changedOnDisk)
    }

    func testAutosaveLeavesAnUntitledBufferAlone() async throws {
        workspace.newFile()
        let document = try XCTUnwrap(workspace.workbench.activePane.selectedDocument)
        document.isDirty = true

        await workspace.autosaveAll(reason: .autosaveIdle)

        XCTAssertNil(document.url)
        XCTAssertTrue(document.isDirty)
    }

    func testTheIdleSettingsAreClampedAndKeptInTheSnapshot() {
        let preferences = IDEPreferences.shared
        let saved = (preferences.saveWhenIdle, preferences.idleSaveSeconds)
        defer { (preferences.saveWhenIdle, preferences.idleSaveSeconds) = saved }

        preferences.idleSaveSeconds = 0
        XCTAssertEqual(preferences.idleSaveSeconds, 1)
        preferences.idleSaveSeconds = 9_999
        XCTAssertEqual(preferences.idleSaveSeconds, 300)

        preferences.idleSaveSeconds = 42
        preferences.saveWhenIdle = false
        let snapshot = preferences.snapshot()
        XCTAssertEqual(snapshot.idleSaveSeconds, 42)
        XCTAssertFalse(snapshot.saveWhenIdle)

        let data = try? JSONEncoder().encode(snapshot)
        let decoded = data.flatMap { try? JSONDecoder().decode(IDEPreferencesSnapshot.self, from: $0) }
        XCTAssertEqual(decoded?.idleSaveSeconds, 42)
    }
}
