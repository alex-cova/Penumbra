import XCTest
@testable import Umbra

/// F12: overlapping Explorer refreshes. A refresh reads the disk off the main actor and splices
/// the listing in afterwards; when two overlap, the one that read the disk first can apply last.
@MainActor
final class IDEProjectModelRefreshOrderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        let created = FileManager.default.temporaryDirectory.appendingPathComponent("refresh-order-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
        // The model spells paths the way the folder does on disk (`/private/var`, not `/var`).
        root = URL(fileURLWithPath: String(cString: realpath(created.path, nil)))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Holds a refresh after it has read the disk until the test opens the gate.
    private final class Gate: @unchecked Sendable {
        private var entered: CheckedContinuation<Void, Never>?
        private var opened: CheckedContinuation<Void, Never>?
        private var hasEntered = false
        private var isOpen = false

        func hold() async {
            hasEntered = true
            entered?.resume()
            entered = nil
            if isOpen { return }
            await withCheckedContinuation { opened = $0 }
        }

        func waitUntilHeld() async {
            if hasEntered { return }
            await withCheckedContinuation { entered = $0 }
        }

        func open() {
            isOpen = true
            opened?.resume()
            opened = nil
        }
    }

    private func names(_ model: IDEProjectModel) -> [String] {
        (model.rootNode?.children ?? []).map { ($0.id as NSString).lastPathComponent }.sorted()
    }

    private func touch(_ name: String) throws {
        try Data().write(to: root.appendingPathComponent(name))
    }

    /// F-10: past the sync budget, `setRoot` paints the top level immediately and the detached
    /// fill completes the tree through the standard refresh protocol — no hook involved.
    func testSetRootPastBudgetPaintsShallowThenFillsDetached() async throws {
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try touch("top.txt")
        try Data().write(to: nested.appendingPathComponent("deep.txt"))
        let previous = IDEProjectModel.maxSyncBuildDirectories
        IDEProjectModel.maxSyncBuildDirectories = 0
        defer { IDEProjectModel.maxSyncBuildDirectories = previous }
        let model = IDEProjectModel()
        model.setRoot(root)
        // First paint is synchronous: the top level is there, the nested file is not yet loaded.
        XCTAssertEqual(names(model), ["nested", "top.txt"])
        let deepPath = nested.appendingPathComponent("deep.txt").path
        XCTAssertNil(model.node(at: deepPath), "deep content arrives with the detached fill")
        var found: IDEFileNode?
        for _ in 0 ..< 200 {
            found = model.node(at: deepPath)
            if found != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(found, "the detached fill completed the tree")
    }

    func testASlowOlderListingDoesNotPutBackAFileThatWasDeleted() async throws {
        try touch("a.txt")
        try touch("b.txt")
        let model = IDEProjectModel()
        model.setRoot(root)
        XCTAssertEqual(names(model), ["a.txt", "b.txt"])

        // Refresh 1 reads the folder while b.txt still exists, then waits.
        let gate = Gate()
        model.refreshHookForTesting = { sequence in if sequence == 1 { await gate.hold() } }
        try touch("c.txt")
        let first = Task { await model.refresh(directories: [root.path]) }
        await gate.waitUntilHeld()

        // b.txt goes away; refresh 2 sees the folder as it is now and is applied first.
        try FileManager.default.removeItem(at: root.appendingPathComponent("b.txt"))
        await model.refresh(directories: [root.path])
        XCTAssertEqual(names(model), ["a.txt", "c.txt"])

        gate.open()
        await first.value
        XCTAssertEqual(names(model), ["a.txt", "c.txt"], "the older listing put b.txt back")
    }

    func testASlowOlderListingDoesNotHideAFileThatWasCreated() async throws {
        try touch("a.txt")
        let model = IDEProjectModel()
        model.setRoot(root)

        let gate = Gate()
        model.refreshHookForTesting = { sequence in if sequence == 1 { await gate.hold() } }
        let first = Task { await model.refresh(directories: [root.path]) }
        await gate.waitUntilHeld()

        try touch("b.txt")
        await model.refresh(directories: [root.path])
        XCTAssertEqual(names(model), ["a.txt", "b.txt"])

        gate.open()
        await first.value
        XCTAssertEqual(names(model), ["a.txt", "b.txt"], "the older listing hid b.txt")
    }

    /// An older refresh of another directory is still news: it must not be dropped for being older.
    func testAnOlderListingOfAnotherDirectoryIsStillApplied() async throws {
        let one = root.appendingPathComponent("one")
        let two = root.appendingPathComponent("two")
        try FileManager.default.createDirectory(at: one, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: two, withIntermediateDirectories: true)
        let model = IDEProjectModel()
        model.setRoot(root)

        let gate = Gate()
        model.refreshHookForTesting = { sequence in if sequence == 1 { await gate.hold() } }
        try Data().write(to: one.appendingPathComponent("x.txt"))
        let first = Task { await model.refresh(directories: [one.path]) }
        await gate.waitUntilHeld()

        try Data().write(to: two.appendingPathComponent("y.txt"))
        await model.refresh(directories: [two.path])
        gate.open()
        await first.value

        XCTAssertEqual(model.node(at: one.path)?.children?.map(\.id).map { ($0 as NSString).lastPathComponent }, ["x.txt"])
        XCTAssertEqual(model.node(at: two.path)?.children?.map(\.id).map { ($0 as NSString).lastPathComponent }, ["y.txt"])
    }

    /// A full rebuild that read the disk before a newer splice is read again instead of replacing it.
    func testAnOlderFullRebuildDoesNotUndoANewerSplice() async throws {
        try touch("a.txt")
        for index in 0 ..< 205 {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("dir\(index)"), withIntermediateDirectories: false
            )
        }
        let model = IDEProjectModel()
        model.setRoot(root)
        let everything = Set((0 ..< 205).map { root.appendingPathComponent("dir\($0)").path })

        let gate = Gate()
        model.refreshHookForTesting = { sequence in if sequence == 1 { await gate.hold() } }
        let rebuild = Task { await model.refresh(directories: everything) }
        await gate.waitUntilHeld()

        try touch("b.txt")
        await model.refresh(directories: [root.path])
        XCTAssertTrue(names(model).contains("b.txt"))

        gate.open()
        await rebuild.value
        XCTAssertTrue(names(model).contains("b.txt"), "the older rebuild dropped b.txt")
    }
}
