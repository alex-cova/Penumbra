import AppKit
import Foundation
import XCTest
@testable import Umbra

/// F13: the window's per-edit fan-out (`IDEWorkspace.textViewDidChange` calls a dozen consumers).
/// Measured 2026-11-04: about 21 µs per call in a debug build on a 400-field Java file, because each
/// consumer only schedules or debounces its real work. The ceiling below is generous (a debug build
/// on a busy machine) and exists to catch a consumer that starts doing synchronous work per keystroke.
@MainActor
final class IDEKeystrokeFanOutTests: XCTestCase {
    func testTheEditNotificationStaysCheapOnTheMainThread() async throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        defer { IDEWorkspace.isSessionPersistenceEnabled = true }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fanout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = IDEWorkspace()
        workspace.bootstrap()
        defer { workspace.teardown() }
        workspace.openProjectFolder(directory)
        let source = (0 ..< 400).map { "    int field\($0) = \($0);" }.joined(separator: "\n")
        let url = directory.appendingPathComponent("Big.java")
        try "class Big {\n\(source)\n}\n".write(to: url, atomically: true, encoding: .utf8)
        await workspace.openDocument(from: url)
        try await Task.sleep(for: .milliseconds(800))
        let textView = try XCTUnwrap(workspace.host(for: workspace.workbench.activePaneID).textView)
        textView.selectedRange = NSRange(location: 40, length: 0)
        for _ in 0 ..< 50 { workspace.textViewDidChange(textView) } // warm
        let runs = 2000
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0 ..< runs { workspace.textViewDidChange(textView) }
        let micros = Double(DispatchTime.now().uptimeNanoseconds - start) / 1000 / Double(runs)
        print("FANOUT textViewDidChange: \(String(format: "%.1f", micros)) µs per call (debug build)")
        XCTAssertLessThan(micros, 500, "textViewDidChange now costs \(micros) µs per keystroke on the main thread")
        withExtendedLifetime(textView) {}
    }
}
