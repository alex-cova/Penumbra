import XCTest
import TestTreeSitterLanguages
@testable import Penumbra

@MainActor
final class MethodSeparatorControllerTests: XCTestCase {
    private func makeController(text: String,
                               configuration: LanguageConfiguration = .javaScript,
                               enabled: Bool = true) -> (MethodSeparatorController, TreeSitterInternalLanguageMode) {
        let mode = LanguageModeFactory.javaScriptLanguageMode(text: text)
        let controller = MethodSeparatorController()
        controller.languageMode = mode
        controller.configuration = configuration
        controller.isEnabled = enabled
        controller.recompute()
        return (controller, mode)
    }

    func testSeparatorRowsForEachMethod() {
        let text = """
        class Widget {
            render() {
                return 1;
            }
            update() {
                return 2;
            }
        }
        """
        let (controller, mode) = makeController(text: text)
        _ = mode
        // Row 0 (class) is dropped; render() is row 1, update() is row 4.
        XCTAssertFalse(controller.separatorRows.contains(0))
        XCTAssertTrue(controller.separatorRows.contains(1))
        XCTAssertTrue(controller.separatorRows.contains(4))
    }

    func testRow0IsNeverASeparator() {
        let (controller, mode) = makeController(text: "function first() {}\nfunction second() {}")
        _ = mode
        XCTAssertFalse(controller.separatorRows.contains(0))
        XCTAssertTrue(controller.separatorRows.contains(1))
    }

    func testDisabledProducesNoRows() {
        let (controller, mode) = makeController(text: "class C {\n  a() {}\n}", enabled: false)
        _ = mode
        XCTAssertTrue(controller.separatorRows.isEmpty)
    }

    func testConfigurationWithSeparatorsOffProducesNoRows() {
        var config = LanguageConfiguration.javaScript
        config.showsMethodSeparators = false
        let (controller, mode) = makeController(text: "class C {\n  a() {}\n}", configuration: config)
        _ = mode
        XCTAssertTrue(controller.separatorRows.isEmpty)
    }

    func testWindowedRecomputeKeepsSeparatorsOutsideTheEditedRows() {
        let (controller, mode) = makeController(text: """
        class Widget {
            render() {
                return 1;
            }
            update() {
                return 2;
            }
        }
        """)
        _ = mode
        XCTAssertTrue(controller.separatorRows.contains(1))
        XCTAssertTrue(controller.separatorRows.contains(4))
        controller.recompute(rowWindow: 1 ... 2)
        XCTAssertTrue(controller.separatorRows.contains(1))
        XCTAssertTrue(controller.separatorRows.contains(4))
    }

    func testOnRowsChangedFiresWhenRowsChange() {
        let mode = LanguageModeFactory.javaScriptLanguageMode(text: "class C {\n  a() {}\n}")
        let controller = MethodSeparatorController()
        var received: [Set<Int>] = []
        controller.onRowsChanged = { received.append($0) }
        controller.languageMode = mode
        controller.configuration = .javaScript
        controller.isEnabled = true
        // isEnabled didSet already recomputed; force an explicit recompute with same result.
        controller.recompute()
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first, controller.separatorRows)
    }
}
