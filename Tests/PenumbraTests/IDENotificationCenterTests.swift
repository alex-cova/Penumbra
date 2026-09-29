import XCTest
@testable import Umbra

@MainActor
final class IDENotificationCenterTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "IDENotificationCenterTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func makeCenter(toastDuration: Duration = .seconds(60)) -> IDENotificationCenter {
        IDENotificationCenter(defaults: defaults, toastDuration: toastDuration)
    }

    func testNewestNotificationComesFirst() {
        let center = makeCenter()
        center.post("first")
        center.post("second")
        XCTAssertEqual(center.items.map(\.title), ["second", "first"])
    }

    func testListIsCappedAtCapacity() {
        let center = makeCenter()
        for index in 0..<(IDENotificationCenter.capacity + 5) {
            center.post("n\(index)")
        }
        XCTAssertEqual(center.items.count, IDENotificationCenter.capacity)
        XCTAssertEqual(center.items.first?.title, "n\(IDENotificationCenter.capacity + 4)")
    }

    func testPostBecomesTheToast() {
        let center = makeCenter()
        center.post("built", severity: .success)
        XCTAssertEqual(center.toast?.title, "built")
    }

    func testDisabledCategoryIsNotRecorded() {
        let center = makeCenter()
        center.setCategory(.git, enabled: false)
        center.post("pushed", category: .git)
        center.post("synced", category: .gradle)
        XCTAssertEqual(center.items.map(\.title), ["synced"])
    }

    func testDisablingACategoryDropsItsExistingEntries() {
        let center = makeCenter()
        center.post("pushed", category: .git, severity: .error)
        center.post("synced", category: .gradle)
        center.setCategory(.git, enabled: false)
        XCTAssertEqual(center.items.map(\.title), ["synced"])
        XCTAssertEqual(center.toast?.title, "synced")
    }

    func testMutedCenterRecordsWithoutAnnouncing() {
        let center = makeCenter()
        center.isMuted = true
        center.post("synced")
        XCTAssertEqual(center.items.count, 1)
        XCTAssertNil(center.toast)
    }

    func testOpeningThePanelClearsTheToastAndSuppressesNewOnes() {
        let center = makeCenter()
        center.post("one")
        center.setPanelPresented(true)
        XCTAssertNil(center.toast)
        center.post("two")
        XCTAssertNil(center.toast)
        XCTAssertEqual(center.items.count, 2)
    }

    func testInfoToastFadesButAnErrorToastStays() async throws {
        let center = makeCenter(toastDuration: .milliseconds(30))
        center.post("done", severity: .success)
        XCTAssertNotNil(center.toast)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertNil(center.toast)
        XCTAssertEqual(center.items.count, 1, "fading the toast keeps the entry")

        center.post("broken", severity: .error)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(center.toast?.title, "broken")
    }

    func testRemoveAndClear() {
        let center = makeCenter()
        center.post("a", severity: .error)
        center.post("b")
        let first = center.items[1]
        center.remove(first.id)
        XCTAssertEqual(center.items.map(\.title), ["b"])
        center.clear()
        XCTAssertTrue(center.items.isEmpty)
        XCTAssertNil(center.toast)
    }

    func testSettingsPersistAcrossInstances() {
        let center = makeCenter()
        center.isMuted = true
        center.setCategory(.git, enabled: false)

        let reloaded = makeCenter()
        XCTAssertTrue(reloaded.isMuted)
        XCTAssertFalse(reloaded.isEnabled(.git))
        XCTAssertTrue(reloaded.isEnabled(.gradle))
    }
}
