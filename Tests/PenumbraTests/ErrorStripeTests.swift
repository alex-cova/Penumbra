import AppKit
@testable import Penumbra
import XCTest

@MainActor
final class ErrorStripeTests: XCTestCase {
    func testTicksAreClampedToTheTrackAndKeepTheirMinimumHeight() {
        let ticks = ErrorStripeView.tickRects(
            for: [
                ErrorStripeMark(fraction: 0, severity: .error),
                ErrorStripeMark(fraction: 1, severity: .error),
                ErrorStripeMark(fraction: 0.5, severity: .warning)
            ],
            trackHeight: 200,
            minimumMarkHeight: 3
        )
        XCTAssertEqual(ticks.count, 3)
        XCTAssertTrue(ticks.allSatisfy { $0.rect.height == 3 && $0.rect.minY >= 0 && $0.rect.maxY <= 200 })
        let warning = ticks.first { $0.severity == .warning }
        XCTAssertEqual(warning?.rect.midY ?? 0, 100, accuracy: 0.01)
    }

    func testMoreSevereTicksArePaintedLast() {
        let ticks = ErrorStripeView.tickRects(
            for: [
                ErrorStripeMark(fraction: 0.5, severity: .error),
                ErrorStripeMark(fraction: 0.5, severity: .hint),
                ErrorStripeMark(fraction: 0.5, severity: .warning)
            ],
            trackHeight: 100,
            minimumMarkHeight: 2
        )
        XCTAssertEqual(ticks.map(\.severity), [.hint, .warning, .error])
    }

    func testNoTrackHeightDrawsNothing() {
        XCTAssertTrue(ErrorStripeView.tickRects(for: [ErrorStripeMark(fraction: 0.3, severity: .error)], trackHeight: 0, minimumMarkHeight: 2).isEmpty)
    }

    func testControllerPositionsDiagnosticsByTheirFractionAndCapsTheCount() {
        let controller = ErrorStripeController()
        controller.fractionForOffset = { offset in offset < 100 ? CGFloat(offset) / 100 : nil }
        controller.isEnabled = true
        controller.setDiagnostics([
            TextViewDiagnostic(range: NSRange(location: 25, length: 1), severity: .error),
            TextViewDiagnostic(range: NSRange(location: 50, length: 1), severity: .warning),
            TextViewDiagnostic(range: NSRange(location: 500, length: 1), severity: .error)
        ])
        XCTAssertEqual(controller.view.marks, [
            ErrorStripeMark(fraction: 0.25, severity: .error),
            ErrorStripeMark(fraction: 0.5, severity: .warning)
        ])
        controller.isEnabled = false
        XCTAssertTrue(controller.view.marks.isEmpty)

        controller.isEnabled = true
        let many = (0..<(ErrorStripeController.maxMarks + 50)).map {
            TextViewDiagnostic(range: NSRange(location: $0 % 90, length: 1), severity: $0 < 50 ? .error : .hint)
        }
        controller.setDiagnostics(many)
        XCTAssertEqual(controller.view.marks.count, ErrorStripeController.maxMarks)
        XCTAssertEqual(controller.view.marks.filter { $0.severity == .error }.count, 50)
    }

    func testTextViewTicksDiagnosticsOnlyWhenTheStripeIsOn() {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.text = (0..<100).map { "line \($0)" }.joined(separator: "\n")
        textView.layoutIfNeeded()
        let offsetOfLine50 = (textView.text as NSString).range(of: "line 50").location
        textView.diagnostics = [TextViewDiagnostic(range: NSRange(location: offsetOfLine50, length: 4), severity: .error)]
        XCTAssertTrue(textView.errorStripeViewForTesting.marks.isEmpty, "the stripe is off by default")

        textView.showsErrorStripe = true
        let marks = textView.errorStripeViewForTesting.marks
        XCTAssertEqual(marks.count, 1)
        XCTAssertEqual(marks[0].severity, .error)
        XCTAssertEqual(marks[0].fraction, 0.5, accuracy: 0.05)

        textView.showsErrorStripe = false
        XCTAssertTrue(textView.errorStripeViewForTesting.marks.isEmpty)
    }

    func testDiagnosticsAtLocationReturnTheOnesCoveringItMostSevereFirst() {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.text = "let value = 1"
        textView.diagnostics = [
            TextViewDiagnostic(range: NSRange(location: 4, length: 5), severity: .warning, message: "unused"),
            TextViewDiagnostic(range: NSRange(location: 4, length: 2), severity: .error, message: "bad"),
            TextViewDiagnostic(range: NSRange(location: 12, length: 0), severity: .hint, message: "empty")
        ]
        XCTAssertEqual(textView.diagnostics(at: 5).map(\.message), ["bad", "unused"])
        XCTAssertEqual(textView.diagnostics(at: 7).map(\.message), ["unused"])
        XCTAssertTrue(textView.diagnostics(at: 9).isEmpty, "the end of a range is not inside it")
        XCTAssertEqual(textView.diagnostics(at: 12).map(\.message), ["empty"])
        XCTAssertTrue(textView.diagnostics(at: 0).isEmpty)
    }
}
