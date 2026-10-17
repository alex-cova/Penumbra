import AppKit
import XCTest
@testable import Penumbra

/// Squiggles follow edits: markers ending before an edit stay, markers after it shift,
/// markers it touches drop (never stretched over retyped text), and the error stripe
/// ticks move with the shifted markers instead of its own stale copy.
@MainActor
final class TextViewDiagnosticShiftTests: XCTestCase {
    private func textView(with text: String) -> TextView {
        let view = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        view.theme = DefaultTheme()
        view.text = text
        view.showsErrorStripe = true
        return view
    }

    private func marker(_ location: Int, _ length: Int, source: String = "Test") -> TextViewDiagnostic {
        TextViewDiagnostic(
            range: NSRange(location: location, length: length),
            severity: .warning,
            message: "problem",
            source: source,
            code: "c"
        )
    }

    private func coveredText(_ view: TextView, _ range: NSRange) -> String {
        (view.text as NSString).substring(with: range)
    }

    func testEnterAboveWarningsShiftsSquigglesAndStripeTicks() async throws {
        let view = textView(with: "ab\ncd\nef\n")
        view.diagnostics = [marker(0, 2), marker(6, 2)]
        try await Task.sleep(nanoseconds: 100_000_000)
        let ticksBefore = view.errorStripeViewForTesting.marks.map(\.fraction)

        // Enter above every warning: both squiggles move down one line.
        view.replace(NSRange(location: 0, length: 0), withText: "\n")

        XCTAssertEqual(view.diagnostics.map(\.range.location), [1, 7])
        XCTAssertEqual(view.diagnostics.map { coveredText(view, $0.range) }, ["ab", "ef"])

        // The stripe recomputes from the shifted markers after its debounce.
        try await Task.sleep(nanoseconds: 400_000_000)
        let marks = view.errorStripeViewForTesting.marks
        XCTAssertEqual(marks.count, 2)
        XCTAssertNotEqual(marks.map(\.fraction), ticksBefore)
    }

    func testEditInsideAWarningDropsItsSquiggle() {
        let view = textView(with: "ab\ncd\n")
        view.diagnostics = [marker(0, 2), marker(3, 2)]

        // Retyping the flagged token drops its squiggle; the warning below shifts.
        view.replace(NSRange(location: 0, length: 1), withText: "x")

        XCTAssertEqual(view.diagnostics.map(\.range.location), [3])
        XCTAssertEqual(coveredText(view, view.diagnostics[0].range), "cd")
    }

    func testEditBeforeWarningsShiftsWithoutChangingIdentity() {
        let view = textView(with: "ab\ncd\n")
        view.diagnostics = [marker(3, 2)]
        let id = view.diagnostics[0].id

        view.replace(NSRange(location: 0, length: 0), withText: "xy")

        XCTAssertEqual(view.diagnostics.count, 1)
        XCTAssertEqual(view.diagnostics[0].id, id)
        XCTAssertEqual(view.diagnostics[0].range.location, 5)
        XCTAssertEqual(coveredText(view, view.diagnostics[0].range), "cd")
    }
}
