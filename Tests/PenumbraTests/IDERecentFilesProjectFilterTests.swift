import Foundation
import XCTest
@testable import Umbra

/// Shift-shift All must not list files from other projects: the closed global
/// recent list is shared by every window, so the palette has to scope it to
/// the open folder. Open documents belong to the window and are always kept.
@MainActor
final class IDERecentFilesProjectFilterTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/proj")

    func testClosedFilesOutsideTheProjectAreDropped() {
        let open = [root.appendingPathComponent("src/Main.java")]
        let closed = [
            root.appendingPathComponent("src/Other.java"),
            URL(fileURLWithPath: "/other/Main.java"),
        ]
        XCTAssertEqual(
            IDEWorkspace.paletteRecentFiles(open: open, closed: closed, root: root),
            [root.appendingPathComponent("src/Main.java"), root.appendingPathComponent("src/Other.java")]
        )
    }

    func testOpenDocumentsAreKeptEvenOutsideTheProject() {
        let external = URL(fileURLWithPath: "/tmp/notes.txt")
        XCTAssertEqual(
            IDEWorkspace.paletteRecentFiles(open: [external], closed: [], root: root),
            [external]
        )
    }

    func testDuplicatesPreferTheOpenEntry() {
        let url = root.appendingPathComponent("src/Main.java")
        XCTAssertEqual(
            IDEWorkspace.paletteRecentFiles(open: [url], closed: [url], root: root),
            [url]
        )
    }

    func testWithoutAProjectEverythingIsKept() {
        let urls = [URL(fileURLWithPath: "/a/Foo.java"), URL(fileURLWithPath: "/b/Bar.java")]
        XCTAssertEqual(IDEWorkspace.paletteRecentFiles(open: [], closed: urls, root: nil), urls)
    }
}
