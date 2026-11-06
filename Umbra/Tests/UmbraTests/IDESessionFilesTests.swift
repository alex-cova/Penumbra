import Foundation
import XCTest
@testable import Umbra

/// The session is split into `app.json` (shared by every window) and `windows.json` (one entry per
/// window), migrated once from the old `session.json` and `last-window.json`.
@MainActor
final class IDESessionFilesTests: XCTestCase {
    private var directory: URL!
    private var files: IDESessionFiles!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IDESessionFilesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        files = IDESessionFiles(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func writeLegacy(_ session: IDELegacySession) throws {
        try JSONEncoder().encode(session).write(to: files.legacyURL)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Migration

    func testMigrationSplitsLegacySessionIntoAppAndWindowFiles() throws {
        var legacy = IDELegacySession.empty
        legacy.recentFiles = [URL(fileURLWithPath: "/tmp/a.java")]
        legacy.recentlyEditedFiles = [URL(fileURLWithPath: "/tmp/b.java")]
        legacy.recentProjects = [URL(fileURLWithPath: "/tmp/project")]
        legacy.projectRootBookmark = Data([1, 2, 3])
        legacy.sidebarWidth = 311
        legacy.isSidebarVisible = true
        legacy.isTerminalVisible = true
        legacy.terminalHeight = 222
        legacy.closedSidebarTabs = [.structure]
        try writeLegacy(legacy)

        files.migrateLegacySessionIfNeeded()

        let app = try XCTUnwrap(files.loadApp())
        XCTAssertEqual(app.recentFiles, legacy.recentFiles)
        XCTAssertEqual(app.recentlyEditedFiles, legacy.recentlyEditedFiles)
        XCTAssertEqual(app.recentProjects, legacy.recentProjects)
        XCTAssertEqual(app.preferences, legacy.preferences)

        let window = try XCTUnwrap(files.loadWindow())
        XCTAssertEqual(window.projectRootBookmark, Data([1, 2, 3]))
        XCTAssertEqual(window.sidebarWidth, 311)
        XCTAssertTrue(window.isSidebarVisible)
        XCTAssertTrue(window.isTerminalVisible)
        XCTAssertEqual(window.terminalHeight, 222)
        XCTAssertEqual(window.closedSidebarTabs, [.structure])
    }

    func testMigrationLeavesTheLegacyFileUntouched() throws {
        try writeLegacy(.empty)
        let before = try Data(contentsOf: files.legacyURL)

        files.migrateLegacySessionIfNeeded()

        XCTAssertEqual(try Data(contentsOf: files.legacyURL), before)
    }

    func testMigrationRunsOnlyOnceAppJSONExists() throws {
        var legacy = IDELegacySession.empty
        legacy.recentProjects = [URL(fileURLWithPath: "/tmp/old")]
        try writeLegacy(legacy)
        files.migrateLegacySessionIfNeeded()

        // The app moves on; a later launch must not bring the old session back over it.
        files.saveApp(IDEAppSessionRecord(recentProjects: [URL(fileURLWithPath: "/tmp/new")]))
        files.saveWindow(IDEWindowSession(sidebarWidth: 400))
        files.migrateLegacySessionIfNeeded()

        XCTAssertEqual(files.loadApp()?.recentProjects, [URL(fileURLWithPath: "/tmp/new")])
        XCTAssertEqual(files.loadWindow()?.sidebarWidth, 400)
    }

    func testNoLegacyFileMeansNoMigration() {
        files.migrateLegacySessionIfNeeded()

        XCTAssertFalse(exists(files.appURL))
        XCTAssertFalse(exists(files.windowURL))
    }

    func testCorruptLegacyFileIsIgnored() throws {
        try Data("not json".utf8).write(to: files.legacyURL)

        files.migrateLegacySessionIfNeeded()

        XCTAssertFalse(exists(files.appURL))
        XCTAssertFalse(exists(files.windowURL))
    }

    /// An older `session.json` has none of the later optional fields (terminal tabs, sidebar tabs).
    func testMigrationReadsAnOlderSessionWithoutLaterFields() throws {
        let legacy = IDELegacySession.empty
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any]
        )
        for key in ["sidebarTab", "closedSidebarTabs", "terminalTabs", "selectedTerminalTabID",
                    "gradleSidebarWidth", "isGradleSidebarVisible", "isTerminalVisible", "terminalHeight",
                    "recentlyEditedFiles", "recentProjects"] {
            object[key] = nil
        }
        try JSONSerialization.data(withJSONObject: object).write(to: files.legacyURL)

        files.migrateLegacySessionIfNeeded()

        let window = try XCTUnwrap(files.loadWindow())
        XCTAssertNil(window.terminalTabs)
        XCTAssertEqual(window.projectSidebarWidth, IDEWindowSession.empty.projectSidebarWidth)
        XCTAssertTrue(window.isProjectSidebarVisible)
        XCTAssertEqual(files.loadApp()?.recentProjects, [])
    }

    /// The right-hand tool window's width and visibility were saved as `gradleSidebarWidth` and
    /// `isGradleSidebarVisible`, when it was always Gradle's. An older `last-window.json` still restores them.
    func testAWindowFileWithTheOldGradleSidebarKeysStillRestores() throws {
        let json = #"{"sidebarWidth": 250, "isSidebarVisible": true, "gradleSidebarWidth": 312, "isGradleSidebarVisible": false}"#
        let window = try JSONDecoder().decode(IDEWindowSession.self, from: Data(json.utf8))
        XCTAssertEqual(window.projectSidebarWidth, 312)
        XCTAssertFalse(window.isProjectSidebarVisible)
        XCTAssertEqual(window.sidebarWidth, 250)
    }

    func testTheNewKeysWinAndAreWhatGetsWritten() throws {
        let json = #"{"projectSidebarWidth": 290, "gradleSidebarWidth": 312, "isProjectSidebarVisible": true, "isGradleSidebarVisible": false}"#
        let window = try JSONDecoder().decode(IDEWindowSession.self, from: Data(json.utf8))
        XCTAssertEqual(window.projectSidebarWidth, 290)
        XCTAssertTrue(window.isProjectSidebarVisible)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(window)) as? [String: Any])
        XCTAssertEqual(object["projectSidebarWidth"] as? Double, 290)
        XCTAssertNil(object["gradleSidebarWidth"])
        XCTAssertNil(object["isGradleSidebarVisible"])
    }

    // MARK: - Round trips and corrupt files

    func testWindowSessionRoundTrip() throws {
        let tabID = UUID()
        let session = IDEWindowSession(
            projectRootBookmark: Data([9, 9]),
            sidebarWidth: 280,
            isSidebarVisible: true,
            projectSidebarWidth: 301,
            isProjectSidebarVisible: false,
            isTerminalVisible: true,
            terminalHeight: 250,
            terminalTabs: [IDETerminalTab(id: tabID, title: "t", workingDirectory: URL(fileURLWithPath: "/tmp"))],
            selectedTerminalTabID: tabID,
            sidebarTab: .changes,
            closedSidebarTabs: [.breakpoints]
        )

        files.saveWindow(session)
        let loaded = try XCTUnwrap(files.loadWindow())

        XCTAssertEqual(loaded.projectRootBookmark, Data([9, 9]))
        XCTAssertEqual(loaded.sidebarWidth, 280)
        XCTAssertEqual(loaded.projectSidebarWidth, 301)
        XCTAssertFalse(loaded.isProjectSidebarVisible)
        XCTAssertEqual(loaded.terminalTabs?.map(\.id), [tabID])
        XCTAssertEqual(loaded.selectedTerminalTabID, tabID)
        XCTAssertEqual(loaded.sidebarTab, .changes)
        XCTAssertEqual(loaded.closedSidebarTabs, [.breakpoints])
    }

    func testCorruptWindowFileDoesNotAffectTheAppFile() throws {
        files.saveApp(IDEAppSessionRecord(recentProjects: [URL(fileURLWithPath: "/tmp/p")]))
        try Data("{ broken".utf8).write(to: files.windowURL)

        XCTAssertNil(files.loadWindow())
        XCTAssertEqual(files.loadApp()?.recentProjects, [URL(fileURLWithPath: "/tmp/p")])
    }

    func testCorruptAppFileDoesNotAffectTheWindowFile() throws {
        files.saveWindow(IDEWindowSession(sidebarWidth: 333))
        try Data("{ broken".utf8).write(to: files.appURL)

        XCTAssertNil(files.loadApp())
        XCTAssertEqual(files.loadWindow()?.sidebarWidth, 333)
    }

    func testMissingFilesLoadAsNil() {
        XCTAssertNil(files.loadApp())
        XCTAssertNil(files.loadWindow())
    }

    // MARK: - Windows (windows.json)

    private func window(_ id: UUID?, width: Double) -> IDEWindowSession {
        IDEWindowSession(windowID: id, sidebarWidth: width)
    }

    func testEveryWindowRoundTripsInOrder() {
        let ids = [UUID(), UUID(), UUID()]
        files.saveWindows([window(ids[0], width: 201), window(ids[1], width: 202), window(ids[2], width: 203)])

        let loaded = files.loadWindows()

        XCTAssertEqual(loaded.map(\.windowID), ids)
        XCTAssertEqual(loaded.map(\.sidebarWidth), [201, 202, 203])
    }

    func testAnOldLastWindowFileBecomesTheOnlyStoredWindow() throws {
        files.saveWindow(IDEWindowSession(projectRootBookmark: Data([7]), sidebarWidth: 321))

        let first = files.loadWindows()

        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?.sidebarWidth, 321)
        XCTAssertEqual(first.first?.projectRootBookmark, Data([7]))
        let id = try XCTUnwrap(first.first?.windowID, "a window with no id is given one")
        XCTAssertTrue(exists(files.windowsURL), "and the id is written, so the window adopts the id the file holds")
        XCTAssertEqual(files.loadWindows().first?.windowID, id, "the same id on every later read")
        XCTAssertTrue(exists(files.windowURL), "last-window.json is left alone for a downgrade")
    }

    func testWindowsJsonWinsOverTheOldLastWindowFile() {
        let id = UUID()
        files.saveWindow(IDEWindowSession(sidebarWidth: 111))
        files.saveWindows([window(id, width: 222)])

        XCTAssertEqual(files.loadWindows().map(\.sidebarWidth), [222])
    }

    func testAnEntryWithoutAnIdGetsOneAndKeepsItsPlace() throws {
        let known = UUID()
        files.saveWindows([window(known, width: 1), window(nil, width: 2)])

        let loaded = files.loadWindows()

        XCTAssertEqual(loaded.map(\.sidebarWidth), [1, 2])
        XCTAssertEqual(loaded[0].windowID, known)
        XCTAssertNotNil(loaded[1].windowID)
        XCTAssertEqual(files.loadWindows().map(\.windowID), loaded.map(\.windowID))
    }

    func testUpsertUpdatesAWindowInPlaceAndPutsANewOneFirst() {
        let a = UUID(), b = UUID(), c = UUID()
        files.saveWindows([window(a, width: 1), window(b, width: 2)])

        files.upsertWindow(window(b, width: 20))
        XCTAssertEqual(files.loadWindows().map(\.windowID), [a, b])
        XCTAssertEqual(files.loadWindows().map(\.sidebarWidth), [1, 20])

        files.upsertWindow(window(c, width: 3))
        XCTAssertEqual(files.loadWindows().map(\.windowID), [c, a, b])
    }

    func testAWindowWithoutAnIdCannotBeStored() {
        files.upsertWindow(window(nil, width: 5))

        XCTAssertFalse(exists(files.windowsURL))
    }

    func testRemovingAWindowDropsOnlyItsEntryAndWritesNothingForAStranger() {
        let a = UUID(), b = UUID()
        files.saveWindows([window(a, width: 1), window(b, width: 2)])

        files.removeWindow(id: a)
        XCTAssertEqual(files.loadWindows().map(\.windowID), [b])

        let before = try? Data(contentsOf: files.windowsURL)
        files.removeWindow(id: UUID())
        XCTAssertEqual(try? Data(contentsOf: files.windowsURL), before)
    }

    func testACorruptWindowsFileLoadsAsNoWindowsAndLeavesTheAppFileAlone() throws {
        files.saveApp(IDEAppSessionRecord(recentProjects: [URL(fileURLWithPath: "/tmp/p")]))
        try Data("{ broken".utf8).write(to: files.windowsURL)

        XCTAssertTrue(files.loadWindows().isEmpty)
        XCTAssertEqual(files.loadApp()?.recentProjects, [URL(fileURLWithPath: "/tmp/p")])
    }

    func testAWindowSessionFromBeforeWindowIdsStillDecodes() throws {
        let old = Data(#"{"sidebarWidth": 250, "isSidebarVisible": true}"#.utf8)

        let decoded = try JSONDecoder().decode(IDEWindowSession.self, from: old)

        XCTAssertNil(decoded.windowID)
        XCTAssertEqual(decoded.sidebarWidth, 250)
    }

    // MARK: - App state

    func testAppStateRestoresRecentsFromDisk() {
        files.saveApp(IDEAppSessionRecord(
            recentFiles: [URL(fileURLWithPath: "/tmp/f")],
            recentlyEditedFiles: [URL(fileURLWithPath: "/tmp/e")],
            recentProjects: [URL(fileURLWithPath: "/tmp/p")]
        ))

        let state = IDEAppState(files: files, preferences: nil)

        XCTAssertEqual(state.recentFiles, [URL(fileURLWithPath: "/tmp/f")])
        XCTAssertEqual(state.recentlyEditedFiles, [URL(fileURLWithPath: "/tmp/e")])
        XCTAssertEqual(state.recentProjects, [URL(fileURLWithPath: "/tmp/p")])
    }

    func testAppStateSavesWhatWasRecorded() {
        let state = IDEAppState(files: files, preferences: nil)
        state.recentProjects = [URL(fileURLWithPath: "/tmp/one")]
        state.recentFiles = [URL(fileURLWithPath: "/tmp/file")]
        state.save()

        let reloaded = IDEAppState(files: files, preferences: nil)
        XCTAssertEqual(reloaded.recentProjects, [URL(fileURLWithPath: "/tmp/one")])
        XCTAssertEqual(reloaded.recentFiles, [URL(fileURLWithPath: "/tmp/file")])
    }

    /// Every window talks to the one `IDEAppState`, so a save after another window recorded a recent
    /// keeps both, where two separate copies would each write back only their own.
    func testRecentsFromTwoWindowsAreBothKept() {
        let state = IDEAppState(files: files, preferences: nil)
        state.recentProjects.insert(URL(fileURLWithPath: "/tmp/from-window-a"), at: 0)
        state.save()
        state.recentProjects.insert(URL(fileURLWithPath: "/tmp/from-window-b"), at: 0)
        state.save()

        XCTAssertEqual(
            files.loadApp()?.recentProjects,
            [URL(fileURLWithPath: "/tmp/from-window-b"), URL(fileURLWithPath: "/tmp/from-window-a")]
        )
    }

    func testUnchangedStateIsNotWrittenAgain() throws {
        let state = IDEAppState(files: files, preferences: nil)
        state.recentProjects = [URL(fileURLWithPath: "/tmp/one")]
        state.save()
        let firstWrite = try FileManager.default.attributesOfItem(atPath: files.appURL.path)[.modificationDate] as? Date

        Thread.sleep(forTimeInterval: 0.05)
        state.save()

        let secondWrite = try FileManager.default.attributesOfItem(atPath: files.appURL.path)[.modificationDate] as? Date
        XCTAssertEqual(firstWrite, secondWrite)
    }

    func testFreshInstallLeavesPreferencesAtTheirDefaults() {
        let state = IDEAppState(files: files, preferences: nil)
        state.save()

        XCTAssertNil(files.loadApp()?.preferences)
    }
}
