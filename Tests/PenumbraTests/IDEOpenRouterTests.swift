import Foundation
import XCTest
@testable import Umbra

/// Where an opened folder or file goes when several windows exist (`IDEOpenRouter`).
final class IDEOpenRouterTests: XCTestCase {
    private let empty = UUID()
    private let alpha = UUID()
    private let beta = UUID()

    private func window(
        _ id: UUID,
        root: String? = nil,
        isEmpty: Bool? = nil,
        primary: Bool = false
    ) -> IDEOpenWindow {
        IDEOpenWindow(
            id: id,
            projectRoot: root.map { URL(fileURLWithPath: $0) },
            isEmpty: isEmpty ?? (root == nil),
            isPrimary: primary
        )
    }

    private func router(_ windows: [IDEOpenWindow], _ preference: IDEOpenFoldersIn = .ask) -> IDEOpenRouter {
        IDEOpenRouter(windows: windows, preference: preference)
    }

    private func folder(_ path: String) -> URL { URL(fileURLWithPath: path) }

    // MARK: - Folders: already open

    func testFolderAlreadyOpenFocusesItsWindow() {
        let r = router([window(empty, primary: true), window(alpha, root: "/work/alpha")])

        XCTAssertEqual(r.routeFolder(folder("/work/alpha"), origin: .external), .focus(alpha))
        XCTAssertEqual(r.routeFolder(folder("/work/alpha"), origin: .window(empty)), .focus(alpha))
    }

    func testFocusIgnoresTrailingSlashAndDotSegments() {
        let r = router([window(alpha, root: "/work/alpha", primary: true)])

        XCTAssertEqual(r.routeFolder(URL(fileURLWithPath: "/work/alpha/"), origin: .external), .focus(alpha))
        XCTAssertEqual(r.routeFolder(URL(fileURLWithPath: "/work/./alpha"), origin: .external), .focus(alpha))
        XCTAssertEqual(r.routeFolder(URL(fileURLWithPath: "/work/beta/../alpha"), origin: .external), .focus(alpha))
    }

    func testFocusFollowsSymlinks() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("IDEOpenRouterTests-\(UUID().uuidString)", isDirectory: true)
        let real = base.appendingPathComponent("real", isDirectory: true)
        let link = base.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: base) }

        let r = IDEOpenRouter(
            windows: [IDEOpenWindow(id: alpha, projectRoot: real, isEmpty: false, isPrimary: true)],
            preference: .ask
        )

        XCTAssertEqual(r.routeFolder(link, origin: .external), .focus(alpha))
    }

    func testSiblingWithSharedPrefixIsNotTheSameFolder() {
        let r = router([window(alpha, root: "/work/alpha", primary: true)])

        XCTAssertNotEqual(r.routeFolder(folder("/work/alpha-two"), origin: .external), .focus(alpha))
    }

    // MARK: - Folders: external opens

    func testExternalOpenReusesAnEmptyPrimaryWindow() {
        let r = router([window(empty, primary: true), window(alpha, root: "/work/alpha")])

        XCTAssertEqual(r.routeFolder(folder("/work/new"), origin: .external), .reuse(empty))
    }

    func testExternalOpenWithPopulatedPrimaryOpensANewWindowWithoutAsking() {
        // Even with the setting on "ask": no window requested the open, so nothing to ask about.
        let r = router([window(alpha, root: "/work/alpha", primary: true), window(empty)], .ask)

        XCTAssertEqual(r.routeFolder(folder("/work/new"), origin: .external), .newWindow)
    }

    func testExternalOpenDoesNotUseAnEmptyWindowThatIsNotPrimary() {
        let r = router([window(alpha, root: "/work/alpha", primary: true), window(empty)])

        XCTAssertEqual(r.routeFolder(folder("/work/new"), origin: .external), .newWindow)
    }

    func testExternalOpenWithNoWindowsOpensANewWindow() {
        XCTAssertEqual(router([]).routeFolder(folder("/work/new"), origin: .external), .newWindow)
    }

    func testExternalOpenTreatsAWindowWithOnlyDocumentsAsPopulated() {
        // A window showing a file but no project is not empty: replacing it would drop the tab.
        let r = router([window(alpha, root: nil, isEmpty: false, primary: true)])

        XCTAssertEqual(r.routeFolder(folder("/work/new"), origin: .external), .newWindow)
    }

    // MARK: - Folders: opened from a window

    func testOpenFromAnEmptyWindowUsesThatWindow() {
        let r = router([window(empty), window(alpha, root: "/work/alpha", primary: true)], .ask)

        XCTAssertEqual(r.routeFolder(folder("/work/new"), origin: .window(empty)), .reuse(empty))
    }

    func testOpenFromAPopulatedWindowFollowsTheSetting() {
        let windows = [window(alpha, root: "/work/alpha", primary: true)]

        XCTAssertEqual(router(windows, .ask).routeFolder(folder("/work/new"), origin: .window(alpha)),
                       .askReplaceOrNew(alpha))
        XCTAssertEqual(router(windows, .newWindow).routeFolder(folder("/work/new"), origin: .window(alpha)),
                       .newWindow)
        XCTAssertEqual(router(windows, .replace).routeFolder(folder("/work/new"), origin: .window(alpha)),
                       .replace(alpha))
    }

    func testOpenFromAWindowThatNoLongerExistsOpensANewWindow() {
        let r = router([window(alpha, root: "/work/alpha", primary: true)])

        XCTAssertEqual(r.routeFolder(folder("/work/new"), origin: .window(UUID())), .newWindow)
    }

    func testAlreadyOpenBeatsTheSettingAndTheOrigin() {
        let r = router(
            [window(alpha, root: "/work/alpha", primary: true), window(beta, root: "/work/beta")],
            .replace
        )

        XCTAssertEqual(r.routeFolder(folder("/work/beta"), origin: .window(alpha)), .focus(beta))
    }

    // MARK: - Files

    func testFileGoesToTheWindowWhoseProjectContainsIt() {
        let r = router([
            window(alpha, root: "/work/alpha", primary: true),
            window(beta, root: "/work/beta")
        ])

        XCTAssertEqual(r.routeFile(URL(fileURLWithPath: "/work/beta/src/B.java")), .window(beta))
        XCTAssertEqual(r.routeFile(URL(fileURLWithPath: "/work/alpha/A.java")), .window(alpha))
    }

    func testFileInANestedProjectGoesToTheInnerWindow() {
        let r = router([
            window(alpha, root: "/work/alpha", primary: true),
            window(beta, root: "/work/alpha/tools/beta")
        ])

        XCTAssertEqual(r.routeFile(URL(fileURLWithPath: "/work/alpha/tools/beta/B.java")), .window(beta))
        XCTAssertEqual(r.routeFile(URL(fileURLWithPath: "/work/alpha/tools/other.java")), .window(alpha))
    }

    func testFileOutsideEveryProjectGoesToThePrimaryWindow() {
        let r = router([window(alpha, root: "/work/alpha"), window(beta, root: "/work/beta", primary: true)])

        XCTAssertEqual(r.routeFile(URL(fileURLWithPath: "/elsewhere/notes.md")), .window(beta))
    }

    func testFileWithAPrefixSiblingIsNotInsideTheProject() {
        let r = router([window(alpha, root: "/work/alpha", primary: true), window(beta, root: "/work/alpha-two")])

        XCTAssertEqual(r.routeFile(URL(fileURLWithPath: "/work/alpha-two/X.java")), .window(beta))
        XCTAssertEqual(r.routeFile(URL(fileURLWithPath: "/work/alpha-twin/X.java")), .window(alpha))
    }

    func testFileWithNoWindowsOpensANewWindow() {
        XCTAssertEqual(router([]).routeFile(URL(fileURLWithPath: "/work/a.java")), .newWindow)
    }

    func testFileFallsBackToTheFirstWindowWhenNoneIsPrimary() {
        let r = router([window(alpha, root: "/work/alpha"), window(beta, root: "/work/beta")])

        XCTAssertEqual(r.routeFile(URL(fileURLWithPath: "/elsewhere/notes.md")), .window(alpha))
    }
}
