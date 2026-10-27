import XCTest
@testable import Umbra

/// Headless tests for `GhosttyMouseReportEncoder` (plan Step 4): mouse
/// reports in, SGR sequences out. Geometry mirrors the C example
/// (800×600 surface, 10×20 cells).
final class GhosttyMouseEncoderTests: XCTestCase {
    private func encoder(tracking SGR: Bool = true) -> (GhosttyVtTerminal, GhosttyMouseReportEncoder) {
        let term = GhosttyVtTerminal(cols: 80, rows: 24)!
        let enc = GhosttyMouseReportEncoder()!
        if SGR {
            // SGR (1006) + normal tracking, as an app like vim would request.
            term.write(Data("\u{1B}[?1000h\u{1B}[?1006h".utf8))
        }
        term.withTerminal {
            enc.syncToTerminal(
                $0, screenWidth: 800, screenHeight: 600,
                cellWidth: 10, cellHeight: 20, anyButtonPressed: false)
        }
        return (term, enc)
    }

    private func encode(
        _ enc: GhosttyMouseReportEncoder,
        _ term: GhosttyVtTerminal,
        _ report: GhosttyMouseReport
    ) -> Data? {
        term.withTerminal { _ in enc.encode(report) }
    }

    func testDisabledTrackingProducesNoOutput() {
        let (term, enc) = encoder(tracking: false)
        XCTAssertNil(encode(enc, term, GhosttyMouseReport(
            action: .press, button: .left, x: 50, y: 40)))
    }

    func testLeftClickSGR() {
        let (term, enc) = encoder()
        // x=50px → col 6, y=40px → row 3 in 1-based SGR coordinates.
        XCTAssertEqual(
            encode(enc, term, GhosttyMouseReport(action: .press, button: .left, x: 50, y: 40)),
            Data("\u{1B}[<0;6;3M".utf8))
    }

    func testReleaseSGR() {
        let (term, enc) = encoder()
        // SGR keeps the button code and marks release with lowercase 'm'.
        XCTAssertEqual(
            encode(enc, term, GhosttyMouseReport(action: .release, button: .left, x: 50, y: 40)),
            Data("\u{1B}[<0;6;3m".utf8))
    }

    func testWheelUpDown() {
        let (term, enc) = encoder()
        // xterm wheel buttons: up = 64, down = 65.
        XCTAssertEqual(
            encode(enc, term, GhosttyMouseReport(action: .press, button: .wheelUp, x: 50, y: 40)),
            Data("\u{1B}[<64;6;3M".utf8))
        XCTAssertEqual(
            encode(enc, term, GhosttyMouseReport(action: .press, button: .wheelDown, x: 50, y: 40)),
            Data("\u{1B}[<65;6;3M".utf8))
    }

    func testMotionWithoutButtonsIsQuietInNormalMode() {
        let (term, enc) = encoder()
        XCTAssertNil(encode(enc, term, GhosttyMouseReport(action: .motion, button: nil, x: 50, y: 40)))
    }
}
