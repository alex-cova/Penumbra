import AppKit
import XCTest
@testable import Penumbra
@testable import Umbra

/// Which pairs, closing braces and tag helpers each language gets from the Smart Keys settings.
final class IDESmartKeysConfigurationTests: XCTestCase {
    private func leadings(_ language: String?, _ switches: IDESmartKeysConfiguration.Switches = .init()) -> [String] {
        IDESmartKeysConfiguration.make(language: language, switches: switches).characterPairs.map(\.leading)
    }

    func testJavaPairsBracketsGenericsAndQuotes() {
        XCTAssertEqual(leadings("java"), ["(", "[", "{", "<", "\"", "'"])
    }

    func testPlainTextAndTabularDataPairNothing() {
        XCTAssertEqual(leadings(nil), [])
        XCTAssertEqual(leadings("plain"), [])
        XCTAssertEqual(leadings("csv"), [])
    }

    func testRustHasNoSingleQuotePairBecauseOfLifetimes() {
        XCTAssertFalse(leadings("rust").contains("'"))
        XCTAssertTrue(leadings("rust").contains("<"))
    }

    func testAngleBracketsAreNotPairedInLanguagesWithoutGenerics() {
        XCTAssertFalse(leadings("python").contains("<"))
        XCTAssertFalse(leadings("html").contains("<"))
    }

    func testBacktickPairsInTemplateLanguages() {
        XCTAssertTrue(leadings("typescript").contains("`"))
        XCTAssertFalse(leadings("java").contains("`"))
    }

    func testSwitchesRemoveTheirOwnPairs() {
        var switches = IDESmartKeysConfiguration.Switches()
        switches.insertPairedQuotes = false
        XCTAssertEqual(leadings("java", switches), ["(", "[", "{", "<"])
        switches.insertPairedBrackets = false
        XCTAssertEqual(leadings("java", switches), [])
    }

    func testClosingBraceOnEnterIsForBracedLanguagesOnly() {
        XCTAssertTrue(IDESmartKeysConfiguration.make(language: "java").insertsClosingBraceOnEnter)
        XCTAssertFalse(IDESmartKeysConfiguration.make(language: "python").insertsClosingBraceOnEnter)
        XCTAssertFalse(IDESmartKeysConfiguration.make(language: "html").insertsClosingBraceOnEnter)
        var switches = IDESmartKeysConfiguration.Switches()
        switches.insertClosingBraceOnEnter = false
        XCTAssertFalse(IDESmartKeysConfiguration.make(language: "java", switches: switches).insertsClosingBraceOnEnter)
    }

    func testTagClosingIsForMarkupWithHTMLVoidElementsOnlyInHTML() {
        let html = IDESmartKeysConfiguration.make(language: "html")
        XCTAssertEqual(html.tagAutoClosing, [.onStartTagCompletion, .onEndTagSlash])
        XCTAssertTrue(html.voidTagNames?.contains("br") == true)

        let xml = IDESmartKeysConfiguration.make(language: "xml")
        XCTAssertEqual(xml.tagAutoClosing, [.onStartTagCompletion, .onEndTagSlash])
        XCTAssertNil(xml.voidTagNames)

        XCTAssertEqual(IDESmartKeysConfiguration.make(language: "java").tagAutoClosing, [])
    }

    func testTagSwitchesAreIndependent() {
        var switches = IDESmartKeysConfiguration.Switches()
        switches.autoCloseTagOnSlash = false
        XCTAssertEqual(IDESmartKeysConfiguration.make(language: "html", switches: switches).tagAutoClosing, [.onStartTagCompletion])
    }
}

@MainActor
final class IDESmartKeysPreferenceTests: XCTestCase {
    private var original: IDEPreferencesSnapshot?

    override func setUp() {
        super.setUp()
        original = IDEPreferences.shared.snapshot()
    }

    override func tearDown() {
        if let original {
            IDEPreferences.shared.restore(from: original)
        }
        super.tearDown()
    }

    func testApplyConfiguresTheEditorForItsLanguage() {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 200, height: 80))
        textView.languageIdentifier = "html"
        IDEPreferences.shared.insertPairedBrackets = true
        IDEPreferences.shared.insertClosingTagOnTagCompletion = true
        IDEPreferences.shared.apply(to: textView)

        XCTAssertTrue(textView.tagAutoClosing.contains(.onStartTagCompletion))
        XCTAssertFalse(textView.characterPairs.isEmpty)

        textView.languageIdentifier = "java"
        IDEPreferences.shared.apply(to: textView)
        XCTAssertTrue(textView.tagAutoClosing.isEmpty)
        XCTAssertTrue(textView.insertsClosingBraceOnEnter)
    }

    func testOlderSnapshotsTurnEverythingOn() throws {
        let snapshot = try XCTUnwrap(original)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
        for key in ["insertPairedBrackets", "insertPairedQuotes", "insertClosingBraceOnEnter",
                    "insertClosingTagOnTagCompletion", "autoCloseTagOnSlash"] {
            object?.removeValue(forKey: key)
        }
        let stripped = try JSONSerialization.data(withJSONObject: try XCTUnwrap(object))
        let decoded = try JSONDecoder().decode(IDEPreferencesSnapshot.self, from: stripped)
        XCTAssertTrue(decoded.insertPairedBrackets)
        XCTAssertTrue(decoded.insertPairedQuotes)
        XCTAssertTrue(decoded.insertClosingBraceOnEnter)
        XCTAssertTrue(decoded.insertClosingTagOnTagCompletion)
        XCTAssertTrue(decoded.autoCloseTagOnSlash)
    }

    func testTurningTheSwitchesOffEmptiesThePairs() {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 200, height: 80))
        textView.languageIdentifier = "java"
        IDEPreferences.shared.insertPairedBrackets = false
        IDEPreferences.shared.insertPairedQuotes = false
        IDEPreferences.shared.insertClosingBraceOnEnter = false
        IDEPreferences.shared.apply(to: textView)
        XCTAssertTrue(textView.characterPairs.isEmpty)
        XCTAssertFalse(textView.insertsClosingBraceOnEnter)
    }
}
