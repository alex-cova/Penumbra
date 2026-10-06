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

    // MARK: HTML entities

    func testHTMLEncodeEscapesMarkupCharacters() {
        XCTAssertEqual(IDEHTMLText.encode(#"<a href="x">Tom & 'Jerry'</a>"#),
                       "&lt;a href=&quot;x&quot;&gt;Tom &amp; &#39;Jerry&#39;&lt;/a&gt;")
        XCTAssertEqual(IDEHTMLText.encode("é 日本"), "é 日本")
    }

    func testHTMLDecodeHandlesNamedAndNumericEntities() {
        XCTAssertEqual(IDEHTMLText.decode("&lt;b&gt; &amp; &quot;x&quot; &#39; &#x26; &#38; &copy; &hellip;"), "<b> & \"x\" ' & & © …")
        XCTAssertEqual(IDEHTMLText.decode("&amp;lt;"), "&lt;", "decodes one level only")
    }

    func testHTMLDecodeLeavesUnknownAndMalformedEntitiesAlone() {
        XCTAssertEqual(IDEHTMLText.decode("&bogus; &#0; &#xD800; & x; &amp"), "&bogus; &#0; &#xD800; & x; &amp")
        XCTAssertEqual(IDEHTMLText.decode("no entities"), "no entities")
    }

    func testHTMLRoundTrip() {
        let text = #"if (a < b && c > "d") { 'e' }"#
        XCTAssertEqual(IDEHTMLText.decode(IDEHTMLText.encode(text)), text)
    }

    // MARK: Hex

    func testHexEncodeAndDecode() {
        XCTAssertEqual(IDEHexText.encode("hi é"), "686920c3a9")
        XCTAssertEqual(IDEHexText.decode("686920c3a9"), "hi é")
        XCTAssertEqual(IDEHexText.decode("0x68 69:20 C3 A9"), "hi é")
    }

    func testHexDecodeRejectsInvalidInput() {
        XCTAssertNil(IDEHexText.decode("abc"), "odd number of digits")
        XCTAssertNil(IDEHexText.decode("zz"))
        XCTAssertNil(IDEHexText.decode(""))
        XCTAssertNil(IDEHexText.decode("ff"), "0xFF is not UTF-8")
    }

    // MARK: String and Unicode escapes

    func testEscapeStringWritesJavaAndJSONEscapes() {
        XCTAssertEqual(IDEStringEscapeText.escape("a\"b\\c\n\td'e\u{01}"), "a\\\"b\\\\c\\n\\td'e\\u0001")
        XCTAssertEqual(IDEStringEscapeText.escape("é 日本"), "é 日本", "non-ASCII is left to Unicode Escape")
    }

    func testUnescapeStringReversesEscapeAndReadsUnicode() {
        let text = "a\"b\\c\r\n\t\u{08}\u{0C}\u{01}é"
        XCTAssertEqual(IDEStringEscapeText.unescape(IDEStringEscapeText.escape(text)), text)
        XCTAssertEqual(IDEStringEscapeText.unescape(#"caf\u00e9 \'q\' \/"#), "café 'q' /")
        XCTAssertEqual(IDEStringEscapeText.unescape(#"\ud83d\ude00"#), "😀")
    }

    func testUnescapeStringRejectsUnknownOrUnfinishedEscapes() {
        XCTAssertNil(IDEStringEscapeText.unescape(#"bad \q"#))
        XCTAssertNil(IDEStringEscapeText.unescape(#"trailing \"#))
        XCTAssertNil(IDEStringEscapeText.unescape(#"short \u12"#))
        XCTAssertNil(IDEStringEscapeText.unescape(#"nothex \u12zz"#))
    }

    func testUnicodeEscapeAndUnescape() {
        XCTAssertEqual(IDEUnicodeEscapeText.escape("café 😀"), #"caf\u00e9 \ud83d\ude00"#)
        XCTAssertEqual(IDEUnicodeEscapeText.unescape(#"caf\u00e9 \ud83d\ude00"#), "café 😀")
        XCTAssertEqual(IDEUnicodeEscapeText.unescape(IDEUnicodeEscapeText.escape("日本語 ABC")), "日本語 ABC")
    }

    func testUnicodeUnescapeLeavesOtherTextAlone() {
        XCTAssertEqual(IDEUnicodeEscapeText.unescape(#"a\nb \u12 \uZZZZ \x41"#), #"a\nb \u12 \uZZZZ \x41"#)
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

    // MARK: Lines

    func testSortLinesIsNaturalAndCaseInsensitive() {
        XCTAssertEqual(IDELineText.sortAscending("file10\nb\nFile2\nA"), "A\nb\nFile2\nfile10")
        XCTAssertEqual(IDELineText.sortDescending("file10\nb\nFile2\nA"), "file10\nFile2\nb\nA")
    }

    func testSortKeepsEqualLinesInOrderAndTheFinalLineBreak() {
        XCTAssertEqual(IDELineText.sortAscending("b\na\nb\n"), "a\nb\nb\n")
        XCTAssertEqual(IDELineText.sortAscending("b\r\na\r\n"), "a\r\nb\r\n")
        XCTAssertEqual(IDELineText.sortAscending("single"), "single")
    }

    func testRemoveDuplicateLinesKeepsTheFirstOfEach() {
        XCTAssertEqual(IDELineText.removeDuplicates("a\nb\na\nc\nb\n"), "a\nb\nc\n")
        XCTAssertEqual(IDELineText.removeDuplicates("A\na"), "A\na", "case matters")
    }

    func testReverseLines() {
        XCTAssertEqual(IDELineText.reverse("1\n2\n3"), "3\n2\n1")
        XCTAssertEqual(IDELineText.reverse("1\n2\n3\n"), "3\n2\n1\n")
    }

    func testRemoveBlankLinesAlsoDropsWhitespaceOnlyLines() {
        XCTAssertEqual(IDELineText.removeBlankLines("a\n\n  \t\nb\n"), "a\nb\n")
        XCTAssertEqual(IDELineText.removeBlankLines("\n\n"), "")
    }

    func testTrimTrailingWhitespaceKeepsIndentation() {
        XCTAssertEqual(IDELineText.trimTrailingWhitespace("  a \t\n\tb   \nc"), "  a\n\tb\nc")
        XCTAssertEqual(IDELineText.trimTrailingWhitespace("a  \r\nb\t\r\n"), "a\r\nb\r\n")
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
            "Encode Base64", "Decode Base64", "URL Encode", "URL Decode",
            "Encode HTML Entities", "Decode HTML Entities", "Hex Encode", "Hex Decode",
            "Escape String", "Unescape String", "Unicode Escape", "Unicode Unescape", "-",
            "Format JSON", "Minify JSON", "-",
            "UPPERCASE", "lowercase", "Title Case", "camelCase", "PascalCase", "snake_case", "kebab-case",
            "SCREAMING_SNAKE_CASE", "-",
            "Sort Lines Ascending", "Sort Lines Descending", "Remove Duplicate Lines", "Reverse Lines",
            "Remove Blank Lines", "Trim Trailing Whitespace"
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

    func testSortLinesOnAMultiCaretSelectionSortsEachSelectionOnItsOwn() throws {
        let textView = makeTextView("b\na\n--\nd\nc")
        textView.selectedRanges = [NSRange(location: 0, length: 3), NSRange(location: 7, length: 3)]
        let item = try XCTUnwrap(submenu(for: textView).items.first { $0.title == "Sort Lines Ascending" })
        NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item)
        XCTAssertEqual(textView.text, "a\nb\n--\nc\nd")
        textView.undoManager?.undo()
        XCTAssertEqual(textView.text, "b\na\n--\nd\nc")
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
