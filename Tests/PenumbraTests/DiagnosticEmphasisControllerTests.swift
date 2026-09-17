import EditorIntelligence
import Foundation
@testable import Penumbra
import XCTest

final class DiagnosticEmphasisControllerTests: XCTestCase {
    func testDiagnosticsRenderAsSquiggles() {
        let lineManager = LineManager(stringView: StringView(string: "let x = 1"))
        let highlightService = HighlightService(lineManager: lineManager)
        let emphasisManager = EmphasisManager()
        emphasisManager.highlightService = highlightService
        let controller = DiagnosticEmphasisController()
        controller.emphasisManager = emphasisManager
        controller.setDiagnostics([
            TextViewDiagnostic(range: NSRange(location: 0, length: 3), severity: .error),
            TextViewDiagnostic(range: NSRange(location: 8, length: 1), severity: .warning)
        ])
        XCTAssertEqual(highlightService.highlightedRanges.count, 2)
        XCTAssertTrue(highlightService.highlightedRanges.allSatisfy {
            if case .squiggle = $0.style {
                return true
            }
            return false
        })
        controller.clearDiagnostics()
        XCTAssertTrue(highlightService.highlightedRanges.isEmpty)
    }

    func testEditorIntelligenceDiagnosticConversion() {
        let range = TextRange(start: TextPosition(line: 0, column: 4, utf16Offset: 4),
                              end: TextPosition(line: 0, column: 5, utf16Offset: 5))
        let diagnostic = Diagnostic(severity: .error,
                                    message: "Unexpected token",
                                    range: range,
                                    source: "test")
        let textViewDiagnostic = TextViewDiagnostic(diagnostic)
        XCTAssertEqual(textViewDiagnostic.range, NSRange(location: 4, length: 1))
        XCTAssertEqual(textViewDiagnostic.severity, TextViewDiagnosticSeverity.error)
        XCTAssertEqual(textViewDiagnostic.id, diagnostic.id.uuidString)
    }
}
