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

    func testLinesInsertedAboveShiftSeparatorsWithoutPublishing() {
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
        var published: [[Int]] = []
        controller.onRowsChanged = { published.append($0) }
        XCTAssertEqual(controller.separatorRows, [1, 4])
        // Two lines inserted after row 0.
        controller.noteLinesReplaced(afterRow: 0, removed: 0, inserted: 2, changedRows: 0 ... 3)
        XCTAssertEqual(controller.separatorRows, [3, 6])
        XCTAssertTrue(published.isEmpty, "shifted rows wait for the parse")
    }

    func testReplacedLinesDropTheirSeparators() {
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
        // Old rows 1–3 (render) removed after row 0; update() moves from row 4 to row 1.
        controller.noteLinesReplaced(afterRow: 0, removed: 3, inserted: 0, changedRows: 0 ... 1)
        XCTAssertEqual(controller.separatorRows, [1])
    }

    /// After edits that add and remove lines, the windowed rescan must give the rows a full scan
    /// of the same text gives.
    func testSeparatorsAfterLineEditsMatchAFullScan() throws {
        let methods = (0 ..< 30).map { "    method\($0)() {\n        return \($0);\n    }" }
        let source = "class Widget {\n" + methods.joined(separator: "\n") + "\n}\n"
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        textView.setState(TextViewState(text: source, theme: DefaultTheme(), language: .javaScript, parsePolicy: .eager))
        textView.languageIdentifier = "javascript"
        textView.showMethodSeparators = true
        textView.layoutIfNeeded()
        pumpMainRunLoop(for: 0.2)
        let controller = try XCTUnwrap(textInputView(in: textView)).methodSeparatorController
        XCTAssertFalse(controller.separatorRows.isEmpty)

        func edit(_ range: NSRange, _ text: String) {
            textView.selectedRange = range
            textView.insertText(text)
            textView.layoutIfNeeded()
            pumpMainRunLoop(for: 0.2)
        }
        let method5 = (textView.text as NSString).range(of: "    method5()")
        edit(NSRange(location: method5.location, length: 0), "\n\n")
        let method20 = (textView.text as NSString).range(of: "    method20()")
        edit(NSRange(location: method20.location - 1, length: 0), "\n    extra() {\n        return 0;\n    }")
        // Remove method10 entirely (four lines joined away).
        let method10 = (textView.text as NSString).range(of: "    method10()")
        let method11 = (textView.text as NSString).range(of: "    method11()")
        edit(NSRange(location: method10.location, length: method11.location - method10.location), "")
        edit(NSRange(location: 0, length: 0), "\n")

        let (fresh, mode) = makeController(text: textView.text)
        _ = mode
        XCTAssertEqual(controller.separatorRows, fresh.separatorRows)
    }

    func testOnRowsChangedFiresWhenRowsChange() {
        let mode = LanguageModeFactory.javaScriptLanguageMode(text: "class C {\n  a() {}\n}")
        let controller = MethodSeparatorController()
        var received: [[Int]] = []
        controller.onRowsChanged = { received.append($0) }
        controller.languageMode = mode
        controller.configuration = .javaScript
        controller.isEnabled = true
        // isEnabled didSet already recomputed; force an explicit recompute with same result.
        controller.recompute()
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first, controller.separatorRows)
    }

    private func textInputView(in view: NSView) -> TextInputView? {
        if let textInputView = view as? TextInputView {
            return textInputView
        }
        return view.subviews.lazy.compactMap { self.textInputView(in: $0) }.first
    }
}
