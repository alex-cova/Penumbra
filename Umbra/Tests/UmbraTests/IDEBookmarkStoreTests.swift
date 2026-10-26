import XCTest
@testable import Umbra

final class IDEBookmarkStoreTests: XCTestCase {
    private var directory: URL!
    private var root: URL!
    private var fileA: URL!
    private var fileB: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("bookmarks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        root = directory.appendingPathComponent("project", isDirectory: true)
        fileA = root.appendingPathComponent("A.java")
        fileB = root.appendingPathComponent("B.java")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> IDEBookmarkStore {
        IDEBookmarkStore(storeURL: directory.appendingPathComponent("bookmarks.json"))
    }

    func testAProjectAlwaysHasADefaultListNamedAfterIt() {
        let store = makeStore()
        let lists = store.lists(project: root)
        XCTAssertEqual(lists.map(\.name), ["project"])
        XCTAssertEqual(store.defaultListID(project: root), lists.first?.id)
        XCTAssertEqual(store.lists(project: root), lists, "reading twice names the same list")
    }

    func testToggleAddsThenRemovesAndRemembersAcrossStores() {
        let store = makeStore()
        let added = store.toggle(atLine: 12, file: fileA, project: root)
        XCTAssertEqual(added?.line, 12)
        XCTAssertEqual(store.bookmarks(forFile: fileA, project: root).map(\.line), [12])

        let reopened = makeStore()
        XCTAssertEqual(reopened.bookmarks(forFile: fileA, project: root).map(\.line), [12])

        XCTAssertNil(reopened.toggle(atLine: 12, file: fileA, project: root))
        XCTAssertTrue(reopened.bookmarks(project: root).isEmpty)
    }

    func testProjectsKeepSeparateBookmarks() {
        let store = makeStore()
        let other = directory.appendingPathComponent("other", isDirectory: true)
        store.toggle(atLine: 1, file: fileA, project: root)
        store.toggle(atLine: 2, file: fileA, project: other)
        XCTAssertEqual(store.bookmarks(project: root).map(\.line), [1])
        XCTAssertEqual(store.bookmarks(project: other).map(\.line), [2])
    }

    func testAMnemonicNamesOneBookmarkPerProject() {
        let store = makeStore()
        store.toggle(atLine: 3, file: fileA, project: root)
        XCTAssertNil(store.setMnemonic("7", atLine: 3, file: fileA, project: root))
        XCTAssertEqual(store.bookmark(withMnemonic: "7", project: root)?.line, 3)

        // A second bookmark takes the mnemonic: the first loses it and is reported.
        let displaced = store.setMnemonic("7", atLine: 9, file: fileB, project: root)
        XCTAssertEqual(displaced?.line, 3)
        XCTAssertEqual(store.bookmark(withMnemonic: "7", project: root)?.filePath, fileB.standardizedFileURL.path)
        XCTAssertNil(store.bookmark(atLine: 3, file: fileA, project: root)?.mnemonic)
    }

    func testSettingTheSameMnemonicAgainOnTheSameLineDisplacesNothing() {
        let store = makeStore()
        store.setMnemonic("A", atLine: 3, file: fileA, project: root)
        XCTAssertNil(store.setMnemonic("A", atLine: 3, file: fileA, project: root))
        XCTAssertEqual(store.bookmarks(project: root).count, 1)
    }

    func testRemovingTheMnemonicKeepsTheBookmark() {
        let store = makeStore()
        store.setMnemonic("A", atLine: 3, file: fileA, project: root)
        store.setMnemonic(nil, atLine: 3, file: fileA, project: root)
        XCTAssertEqual(store.bookmarks(project: root).map(\.mnemonic), [nil])
    }

    func testMnemonicCharactersAreDigitsAndUppercasedLetters() {
        XCTAssertEqual(IDEBookmarkMnemonic.normalized("q"), "Q")
        XCTAssertEqual(IDEBookmarkMnemonic.normalized("5"), "5")
        XCTAssertNil(IDEBookmarkMnemonic.normalized("-"))
        XCTAssertNil(IDEBookmarkMnemonic.normalized("é"))
    }

    func testDeletingAListDeletesItsBookmarksButNotTheLastList() {
        let store = makeStore()
        let defaultID = store.defaultListID(project: root)!
        let extra = store.createList(named: "Debugging", project: root)
        let kept = store.toggle(atLine: 1, file: fileA, project: root)!
        let moved = store.toggle(atLine: 2, file: fileA, project: root)!
        store.move(bookmarkID: moved.id, toList: extra.id, project: root)

        store.deleteList(extra.id, project: root)
        XCTAssertEqual(store.bookmarks(project: root).map(\.id), [kept.id])
        XCTAssertEqual(store.lists(project: root).map(\.id), [defaultID])

        store.deleteList(defaultID, project: root)
        XCTAssertEqual(store.lists(project: root).map(\.id), [defaultID], "the last list stays")
        XCTAssertEqual(store.bookmarks(project: root).count, 1)
    }

    func testNewBookmarksGoToTheDefaultListWhichCanChange() {
        let store = makeStore()
        let extra = store.createList(named: "Review", project: root)
        store.setDefaultList(extra.id, project: root)
        let bookmark = store.toggle(atLine: 4, file: fileA, project: root)!
        XCTAssertEqual(bookmark.listID, extra.id)
    }

    func testMoveLinesFollowsEditsAndDropsDeletedLines() {
        let store = makeStore()
        let one = store.toggle(atLine: 3, file: fileA, project: root)!
        let two = store.toggle(atLine: 8, file: fileA, project: root)!
        let elsewhere = store.toggle(atLine: 8, file: fileB, project: root)!

        XCTAssertTrue(store.moveLines(in: fileA, to: [two.id: 9], removing: [one.id], project: root))

        XCTAssertEqual(store.bookmarks(forFile: fileA, project: root).map(\.line), [9])
        XCTAssertEqual(store.bookmark(atLine: 8, file: fileB, project: root)?.id, elsewhere.id, "other files are untouched")
        XCTAssertFalse(store.moveLines(in: fileA, to: [two.id: 9], removing: [], project: root), "nothing changed, nothing written")
    }

    func testNextAndPreviousWalkByPathThenLineAndWrap() {
        let store = makeStore()
        store.toggle(atLine: 5, file: fileA, project: root)
        store.toggle(atLine: 20, file: fileA, project: root)
        store.toggle(atLine: 2, file: fileB, project: root)
        let a = fileA.standardizedFileURL.path
        let b = fileB.standardizedFileURL.path

        XCTAssertEqual(store.neighbour(of: (a, 5), forward: true, project: root)?.line, 20)
        XCTAssertEqual(store.neighbour(of: (a, 20), forward: true, project: root)?.filePath, b)
        XCTAssertEqual(store.neighbour(of: (b, 2), forward: true, project: root)?.line, 5, "wraps to the first")
        XCTAssertEqual(store.neighbour(of: (a, 5), forward: false, project: root)?.filePath, b, "wraps to the last")
        XCTAssertEqual(store.neighbour(of: (a, 12), forward: false, project: root)?.line, 5)
        XCTAssertNil(makeStore().neighbour(of: (a, 1), forward: true, project: directory.appendingPathComponent("empty")))
    }

    func testChangesFromAnotherStoreAreNotOverwritten() {
        let first = makeStore()
        let second = makeStore()
        first.toggle(atLine: 1, file: fileA, project: root)
        second.toggle(atLine: 2, file: fileA, project: root)
        XCTAssertEqual(first.bookmarks(project: root).map(\.line).sorted(), [1, 2])
    }

    func testOlderFilesWithoutListsStillLoad() throws {
        let url = directory.appendingPathComponent("bookmarks.json")
        try Data(#"{"\#(root.standardizedFileURL.path)":{"bookmarks":[]}}"#.utf8).write(to: url)
        let store = IDEBookmarkStore(storeURL: url)
        XCTAssertEqual(store.lists(project: root).count, 1)
    }
}
