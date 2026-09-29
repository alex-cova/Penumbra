import XCTest
@testable import JavaIntelligence

final class JDKSelectionStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private var storeURL: URL { directory.appendingPathComponent("jdk-selection.json") }

    func testSelectionsRoundTripThroughTheFile() {
        let project = URL(fileURLWithPath: "/work/app")
        let store = JDKSelectionStore(storeURL: storeURL)
        store.setProject(URL(fileURLWithPath: "/jdks/17"), forProject: project)
        store.setGlobal(URL(fileURLWithPath: "/jdks/21"))

        let reopened = JDKSelectionStore(storeURL: storeURL)
        let selection = reopened.selection(forProject: project)
        XCTAssertEqual(selection.project?.path, "/jdks/17")
        XCTAssertEqual(selection.global?.path, "/jdks/21")
    }

    func testProjectsKeepTheirOwnChoice() {
        let store = JDKSelectionStore(storeURL: storeURL)
        store.setProject(URL(fileURLWithPath: "/jdks/17"), forProject: URL(fileURLWithPath: "/work/a"))
        XCTAssertNil(store.selection(forProject: URL(fileURLWithPath: "/work/b")).project)
        XCTAssertNil(store.selection(forProject: nil).project)
    }

    func testNilPutsAProjectOrTheDefaultBackOnAutomatic() {
        let project = URL(fileURLWithPath: "/work/a")
        let store = JDKSelectionStore(storeURL: storeURL)
        store.setProject(URL(fileURLWithPath: "/jdks/17"), forProject: project)
        store.setGlobal(URL(fileURLWithPath: "/jdks/21"))
        store.setProject(nil, forProject: project)
        store.setGlobal(nil)
        XCTAssertEqual(store.selection(forProject: project), JDKSelection())
        XCTAssertEqual(JDKSelectionStore(storeURL: storeURL).selection(forProject: project), JDKSelection())
    }

    func testACorruptFileGivesAnEmptyStore() throws {
        try Data("not json".utf8).write(to: storeURL)
        let store = JDKSelectionStore(storeURL: storeURL)
        XCTAssertEqual(store.selection(forProject: URL(fileURLWithPath: "/work/a")), JDKSelection())
        XCTAssertTrue(store.customJDKs.isEmpty)
    }

    func testCustomJDKsAddRemoveAndDeduplicate() throws {
        let real = directory.appendingPathComponent("real-jdk")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = directory.appendingPathComponent("link-jdk")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let store = JDKSelectionStore(storeURL: storeURL)
        XCTAssertTrue(store.addCustomJDK(real))
        XCTAssertFalse(store.addCustomJDK(link), "a symlink to an added JDK is the same JDK")
        XCTAssertEqual(store.customJDKs.count, 1)
        XCTAssertEqual(JDKSelectionStore(storeURL: storeURL).customJDKs.count, 1)

        store.removeCustomJDK(link)
        XCTAssertTrue(store.customJDKs.isEmpty)
    }

    func testRemovingACustomJDKLeavesTheSelectionStale() throws {
        let home = directory.appendingPathComponent("custom-jdk")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let project = URL(fileURLWithPath: "/work/a")
        let store = JDKSelectionStore(storeURL: storeURL)
        store.addCustomJDK(home)
        store.setProject(home, forProject: project)
        store.setGlobal(home)

        let usage = store.usage(of: home)
        XCTAssertEqual(usage.projects, ["/work/a"])
        XCTAssertTrue(usage.isDefault)

        store.removeCustomJDK(home)
        XCTAssertEqual(store.selection(forProject: project).project?.lastPathComponent, "custom-jdk")
    }
}
