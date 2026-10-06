import AppKit
import Penumbra
import XCTest

@testable import Umbra

final class IDETextTransformTests: XCTestCase {
    // MARK: URL

    func testURLEncodeAndDecodeRoundTrip() {
        XCTAssertEqual(IDEURLText.encode("a b&c=d/é"), "a%20b%26c%3Dd%2F%C3%A9")
        XCTAssertEqual(IDEURLText.decode("a%20b%26c%3Dd%2F%C3%A9"), "a b&c=d/é")
        XCTAssertEqual(IDEURLText.encode("safe-._~09AZaz"), "safe-._~09AZaz")
    }

    func testURLDecodeKeepsPlusAndRejectsBadEscapes() {
        XCTAssertEqual(IDEURLText.decode("a+b"), "a+b")
        XCTAssertNil(IDEURLText.decode("100%zz"))
    }

    // MARK: JSON

    func testJSONFormatNestedValues() {
        let input = #"{"b":1,"a":[1,2,{"c":null}],"e":{},"l":[],"s":"x,{y}:\"z\""}"#
        let expected = """
        {
          "b": 1,
          "a": [
            1,
            2,
            {
              "c": null
            }
          ],
          "e": {},
          "l": [],
          "s": "x,{y}:\\"z\\""
        }
        """
        XCTAssertEqual(IDEJSONText.format(input), expected)
    }

    func testJSONFormatKeepsOrderNumbersAndEscapes() {
        let formatted = IDEJSONText.format("{\"z\":1.0,\"a\":1e10,\"big\":12345678901234567890,\"u\":\"\\u00e9\\/\"}")
        XCTAssertEqual(formatted, """
        {
          "z": 1.0,
          "a": 1e10,
          "big": 12345678901234567890,
          "u": "\\u00e9\\/"
        }
        """)
    }

    func testJSONFormatUsesIndentUnitAndBaseIndent() {
        XCTAssertEqual(IDEJSONText.format(#"{"a":[1]}"#, indentUnit: "\t", baseIndent: "    "),
                       "{\n    \t\"a\": [\n    \t\t1\n    \t]\n    }")
    }

    func testJSONFormatKeepsSurroundingWhitespaceAndFragments() {
        XCTAssertEqual(IDEJSONText.format("  [1,2]\n"), "  [\n  1,\n  2\n]\n")
        XCTAssertEqual(IDEJSONText.format("42"), "42")
        XCTAssertEqual(IDEJSONText.format("\"hi\""), "\"hi\"")
    }

    func testJSONMinify() {
        let pretty = "{\n  \"a\": [1, 2],\n  \"s\": \"keep  spaces\"\n}"
        XCTAssertEqual(IDEJSONText.minify(pretty), #"{"a":[1,2],"s":"keep  spaces"}"#)
        XCTAssertEqual(IDEJSONText.minify(IDEJSONText.format(pretty) ?? ""), #"{"a":[1,2],"s":"keep  spaces"}"#)
    }

    func testJSONRejectsInvalidText() {
        XCTAssertNil(IDEJSONText.format("{a: 1}"))
        XCTAssertNil(IDEJSONText.format(""))
        XCTAssertNil(IDEJSONText.minify("{\"a\": }"))
        XCTAssertNil(IDEJSONText.format("hello"))
    }

    // MARK: Case

    func testIdentifierStylesFromEveryInputStyle() {
        for input in ["user_name", "userName", "UserName", "user-name", "USER NAME", "user.name"] {
            XCTAssertEqual(IDECaseText.convert(input, to: .camel), "userName", input)
            XCTAssertEqual(IDECaseText.convert(input, to: .pascal), "UserName", input)
            XCTAssertEqual(IDECaseText.convert(input, to: .snake), "user_name", input)
            XCTAssertEqual(IDECaseText.convert(input, to: .kebab), "user-name", input)
            XCTAssertEqual(IDECaseText.convert(input, to: .screamingSnake), "USER_NAME", input)
        }
    }

    func testAcronymsAndDigits() {
        XCTAssertEqual(IDECaseText.convert("HTTPServerURL", to: .snake), "http_server_url")
        XCTAssertEqual(IDECaseText.convert("version2Id", to: .snake), "version2_id")
        XCTAssertEqual(IDECaseText.convert("parseXML", to: .kebab), "parse-xml")
    }

    func testIdentifierStylesWorkLineByLineAndKeepIndentation() {
        XCTAssertEqual(IDECaseText.convert("  fooBar\n\tbaz_qux  \n\nQuux", to: .snake), "  foo_bar\n\tbaz_qux  \n\nquux")
    }

    func testPlainCaseConversions() {
        XCTAssertEqual(IDECaseText.uppercase("Hello wörld"), "HELLO WÖRLD")
        XCTAssertEqual(IDECaseText.lowercase("Hello WÖRLD"), "hello wörld")
        XCTAssertEqual(IDECaseText.titleCase("hello big world"), "Hello Big World")
    }

    // MARK: Registry

    func testRegistryIsConsistent() {
        let ids = IDETextTransforms.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for group in IDETextTransform.Group.allCases {
            XCTAssertFalse(IDETextTransforms.all.filter { $0.group == group }.isEmpty)
        }
        XCTAssertEqual(IDETextTransforms.transform(id: "json.format")?.title, "Format JSON")
    }
}

@MainActor
final class IDETextToolsMenuTests: XCTestCase {
    private var window: NSWindow!

    private func makeTextView(_ text: String) -> TextView {
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        textView.theme = DefaultTheme()
        textView.indentStrategy = .space(length: 2)
        textView.text = text
        window.contentView = textView
        return textView
    }

    private func submenu(for textView: TextView) throws -> NSMenu {
        IDEWorkspace.isSessionPersistenceEnabled = false
        let context = EditorContextMenuContext(location: 0, selectedRange: textView.selectedRange)
        let items = IDEWorkspace().textToolsContextMenuItems(context: context, textView: textView)
        return try XCTUnwrap(items.first { $0.title == "Tools" }?.submenu)
    }

    func testSubmenuListsEveryTransformInGroupOrder() throws {
        let textView = makeTextView("abc")
        textView.selectedRange = NSRange(location: 0, length: 3)
        let menu = try submenu(for: textView)
        let titles = menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
        XCTAssertEqual(titles, [
            "Encode Base64", "Decode Base64", "URL Encode", "URL Decode", "-",
            "Format JSON", "Minify JSON", "-",
            "UPPERCASE", "lowercase", "Title Case", "camelCase", "PascalCase", "snake_case", "kebab-case",
            "SCREAMING_SNAKE_CASE"
        ])
    }

    func testFormatJSONKeepsTheBlockIndentSelectsTheResultAndUndoesInOneStep() throws {
        let original = "    {\"a\":[1,2]}"
        let textView = makeTextView(original)
        textView.selectedRange = NSRange(location: 4, length: original.utf16.count - 4)
        let item = try XCTUnwrap(submenu(for: textView).items.first { $0.title == "Format JSON" })
        NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item)

        let expected = "    {\n      \"a\": [\n        1,\n        2\n      ]\n    }"
        XCTAssertEqual(textView.text, expected)
        XCTAssertEqual(textView.selectedRanges, [NSRange(location: 4, length: expected.utf16.count - 4)])
        textView.undoManager?.undo()
        XCTAssertEqual(textView.text, original)
    }

    func testPaletteTransformWithoutSelectionConvertsTheWholeDocument() {
        let textView = makeTextView(#"{"a":1}"#)
        textView.selectedRange = NSRange(location: 2, length: 0)
        let format = IDETextTransforms.transform(id: "json.format")!
        IDEWorkspace.applyTextTransform(format, in: textView, wholeDocumentWithoutSelection: true)
        XCTAssertEqual(textView.text, "{\n  \"a\": 1\n}")
    }

    func testMenuPathDoesNothingWithoutSelection() {
        let textView = makeTextView(#"{"a":1}"#)
        textView.selectedRange = NSRange(location: 2, length: 0)
        let format = IDETextTransforms.transform(id: "json.format")!
        IDEWorkspace.applyTextTransform(format, in: textView, wholeDocumentWithoutSelection: false)
        XCTAssertEqual(textView.text, #"{"a":1}"#)
    }
}
