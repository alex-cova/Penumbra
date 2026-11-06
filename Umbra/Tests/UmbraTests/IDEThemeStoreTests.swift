import Observation
import XCTest
@testable import Umbra

/// The colour scheme and UI font live in one observable store: a SwiftUI body that reads a token is
/// re-evaluated when it changes, off-main readers stay legal, and AppKit views are told by
/// notification.
/// Counts calls from `withObservationTracking`'s `@Sendable` onChange closure.
private final class Counter: @unchecked Sendable {
    var value = 0
}

@MainActor
final class IDEThemeStoreTests: XCTestCase {
    private let store = IDEThemeStore.shared
    private var savedScheme: IDEUIColorScheme!
    private var savedFamily = ""
    private var savedSize = 0.0

    private var light: IDEUIColorScheme { IDEUmbraLightUIColorScheme.shared }
    private var dark: IDEUIColorScheme { IDEUmbraUIColorScheme.shared }

    override func setUp() {
        savedScheme = store.scheme
        savedFamily = store.fontFamily
        savedSize = store.fontSize
        store.setScheme(dark)
    }

    override func tearDown() {
        store.setScheme(savedScheme)
        store.setFontFamily(savedFamily)
        store.setFontSize(savedSize)
    }

    func testReadingATokenIsTrackedAndAChangeNotifiesOnce() {
        let changes = Counter()
        withObservationTracking {
            _ = IDEAppearance.ColorToken.accent
        } onChange: {
            changes.value += 1
        }

        store.setScheme(light)

        XCTAssertEqual(changes.value, 1)
    }

    func testReadingTheFontIsTrackedToo() {
        let changes = Counter()
        withObservationTracking {
            _ = IDEAppearance.Typography.body
        } onChange: {
            changes.value += 1
        }

        store.setFontSize(store.fontSize + 2)

        XCTAssertEqual(changes.value, 1)
    }

    func testSettingTheSameSchemeChangesNothingAndPostsNothing() {
        let changes = Counter()
        withObservationTracking {
            _ = store.scheme
        } onChange: {
            changes.value += 1
        }
        let posted = expectation(description: "no notification")
        posted.isInverted = true
        let token = NotificationCenter.default.addObserver(
            forName: IDEAppearance.didChangeNotification, object: nil, queue: .main
        ) { _ in posted.fulfill() }
        defer { NotificationCenter.default.removeObserver(token) }

        store.setScheme(dark)

        wait(for: [posted], timeout: 0.1)
        XCTAssertEqual(changes.value, 0)
    }

    func testAnOffMainReaderSeesTheCurrentScheme() async {
        store.setScheme(light)

        let id = await Task.detached { IDEAppearance.scheme.id }.value

        XCTAssertEqual(id, light.id)
    }

    func testAppearanceObserverHearsChangesUntilItIsReleased() {
        var heard = 0
        var observer: IDEAppearanceObserver? = IDEAppearanceObserver { heard += 1 }

        store.setScheme(light)
        store.setFontSize(store.fontSize + 1)
        XCTAssertEqual(heard, 2, "a scheme change and a font change each notify")

        observer = nil
        store.setScheme(dark)
        XCTAssertEqual(heard, 2, "a released observer hears nothing more")
        _ = observer
    }

    func testTheOldStaticsAreGone() {
        // The scheme is derived from the store, so the tokens always agree with it.
        store.setScheme(light)
        XCTAssertEqual(IDEAppearance.scheme.id, light.id)
        XCTAssertEqual(IDEAppearance.preferredColorScheme, .light)
        store.setScheme(dark)
        XCTAssertEqual(IDEAppearance.preferredColorScheme, .dark)
    }
}
