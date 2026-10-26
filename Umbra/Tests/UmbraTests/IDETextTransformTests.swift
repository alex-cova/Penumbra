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

    // MARK: Hashes

    func testHashesOfKnownInputs() {
        XCTAssertEqual(IDEHashText.hash("abc", using: .md5), "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(IDEHashText.hash("abc", using: .sha1), "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(IDEHashText.hash("abc", using: .sha256),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(IDEHashText.hash("abc", using: .sha512).prefix(32), "ddaf35a193617abacc417349ae204131")
        XCTAssertEqual(IDEHashText.hash("", using: .sha256),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testHashCoversTheWholeTextIncludingLineBreaks() {
        XCTAssertNotEqual(IDEHashText.hash("a\nb", using: .sha256), IDEHashText.hash("a b", using: .sha256))
        XCTAssertEqual(IDEHashText.hash("é", using: .md5), "66ddcd97cfdeabb2f6fb8a999b4bc76f", "hashes the UTF-8 bytes")
    }

    // MARK: Unix time

    func testEpochToDateReadsSecondsAndMilliseconds() {
        XCTAssertEqual(IDEConversionText.epochToDate("1700000000"), "2023-11-14T22:13:20Z")
        XCTAssertEqual(IDEConversionText.epochToDate("1700000000000"), "2023-11-14T22:13:20Z")
        XCTAssertEqual(IDEConversionText.epochToDate("1700000000123"), "2023-11-14T22:13:20.123Z")
        XCTAssertEqual(IDEConversionText.epochToDate("0"), "1970-01-01T00:00:00Z")
        XCTAssertEqual(IDEConversionText.epochToDate("-1"), "1969-12-31T23:59:59Z")
        XCTAssertEqual(IDEConversionText.epochToDate("-1500"), "1969-12-31T23:35:00Z", "negative values are not milliseconds below 12 digits")
    }

    func testDateToEpochAcceptsCommonFormats() {
        XCTAssertEqual(IDEConversionText.dateToEpoch("2023-11-14T22:13:20Z"), "1700000000")
        XCTAssertEqual(IDEConversionText.dateToEpoch("2023-11-14T23:13:20+01:00"), "1700000000")
        XCTAssertEqual(IDEConversionText.dateToEpoch("2023-11-14T22:13:20.999Z"), "1700000000")
        XCTAssertEqual(IDEConversionText.dateToEpoch("2023-11-14"), "1699920000")
        XCTAssertEqual(IDEConversionText.dateToEpoch("2023-11-14 22:13:20"), "1700000000")
        XCTAssertNil(IDEConversionText.dateToEpoch("next tuesday"))
        XCTAssertNil(IDEConversionText.dateToEpoch("2023-11-14 garbage"), "trailing text is not ignored")
        XCTAssertNil(IDEConversionText.dateToEpoch("2023-11-14T22:13:20Z garbage"))
        XCTAssertNil(IDEConversionText.dateToEpoch("2023-02-31"), "not a real date")
    }

    func testTimeConversionsWorkLineByLineAndKeepBlankLines() {
        XCTAssertEqual(IDEConversionText.epochToDate("  0\n\n1700000000 "), "  1970-01-01T00:00:00Z\n\n2023-11-14T22:13:20Z ")
        XCTAssertNil(IDEConversionText.epochToDate("0\nnope"), "one bad line refuses the whole selection")
        XCTAssertNil(IDEConversionText.epochToDate("\n\n"), "nothing to convert")
    }

    // MARK: Number bases

    func testNumberBases() {
        XCTAssertEqual(IDEConversionText.toHex("255"), "0xff")
        XCTAssertEqual(IDEConversionText.toBinary("255"), "0b11111111")
        XCTAssertEqual(IDEConversionText.toDecimal("0xff"), "255")
        XCTAssertEqual(IDEConversionText.toDecimal("0b1010"), "10")
        XCTAssertEqual(IDEConversionText.toDecimal("0o17"), "15")
        XCTAssertEqual(IDEConversionText.toHex("-255"), "-0xff")
        XCTAssertEqual(IDEConversionText.toHex("1_000L"), "0x3e8", "Java separators and suffix")
        XCTAssertEqual(IDEConversionText.toHex("18446744073709551615"), "0xffffffffffffffff")
    }

    func testNumberBasesRejectNonNumbersAndConvertEachLine() {
        XCTAssertNil(IDEConversionText.toHex("ff"), "hex needs its 0x prefix")
        XCTAssertNil(IDEConversionText.toHex("12.5"))
        XCTAssertNil(IDEConversionText.toDecimal("0xzz"))
        XCTAssertEqual(IDEConversionText.toHex("1\n  16\n"), "0x1\n  0x10\n")
    }

    // MARK: JWT

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testJWTDecodesHeaderPayloadAndSignature() throws {
        let token = IDEJWTTestToken.make(
            header: #"{"alg":"HS256","typ":"JWT"}"#,
            payload: #"{"sub":"1234567890","name":"Jane","admin":true,"iat":1699999000,"exp":1700003600}"#,
            signature: "c2lnbmF0dXJl")
        let decoding = try XCTUnwrap(IDEJWTText.decode(token, now: now))
        XCTAssertEqual(decoding.algorithm, "HS256")
        XCTAssertEqual(decoding.header, "{\n  \"alg\": \"HS256\",\n  \"typ\": \"JWT\"\n}")
        XCTAssertTrue(decoding.payload.contains("\"name\": \"Jane\""))
        XCTAssertEqual(decoding.signature, "c2lnbmF0dXJl")
        XCTAssertEqual(decoding.timeClaims.map(\.name), ["iat", "exp"])
        XCTAssertEqual(decoding.status, .valid(until: Date(timeIntervalSince1970: 1_700_003_600)))
    }

    func testJWTStatusExpiredNotYetValidAndNoExpiry() throws {
        func status(_ payload: String) throws -> IDEJWTDecoding.Status {
            try XCTUnwrap(IDEJWTText.decode(IDEJWTTestToken.make(header: #"{"alg":"none"}"#, payload: payload), now: now)).status
        }
        XCTAssertEqual(try status(#"{"exp":1699999999}"#), .expired(at: Date(timeIntervalSince1970: 1_699_999_999)))
        XCTAssertEqual(try status(#"{"nbf":1700000100,"exp":1700009999}"#), .notYetValid(from: Date(timeIntervalSince1970: 1_700_000_100)))
        XCTAssertEqual(try status(#"{"sub":"x"}"#), .noExpiry)
        XCTAssertEqual(try status(#"{"exp":true}"#), .noExpiry, "a boolean is not a time")
    }

    func testJWTIgnoresBearerPrefixQuotesAndWhitespace() throws {
        let token = IDEJWTTestToken.make(header: #"{"alg":"HS256"}"#, payload: #"{"a":1}"#)
        XCTAssertNotNil(IDEJWTText.decode("Bearer \(token)"))
        XCTAssertNotNil(IDEJWTText.decode("Authorization: bearer \(token)\n"))
        XCTAssertNotNil(IDEJWTText.decode("\"\(token)\""))
        let parts = token.components(separatedBy: ".")
        XCTAssertNotNil(IDEJWTText.decode(parts.joined(separator: ".\n  ")))
    }

    func testJWTUnsecuredTokenHasNoSignature() throws {
        let token = IDEJWTTestToken.make(header: #"{"alg":"none"}"#, payload: #"{"a":1}"#, signature: "")
        XCTAssertEqual(try XCTUnwrap(IDEJWTText.decode(token)).signature, "")
    }

    func testJWTRejectsWhatIsNotAToken() {
        XCTAssertNil(IDEJWTText.decode(""))
        XCTAssertNil(IDEJWTText.decode("not.a.token"))
        XCTAssertNil(IDEJWTText.decode("a.b"))
        XCTAssertNil(IDEJWTText.decode("a.b.c.d.e"), "an encrypted JWE")
        XCTAssertNil(IDEJWTText.decode(IDEJWTTestToken.make(header: "[1]", payload: #"{"a":1}"#)), "header must be an object")
        XCTAssertNil(IDEJWTText.decode(IDEJWTTestToken.make(header: #"{"alg":"x"}"#, payload: "plain text")))
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

    private func item(titled title: String, in tools: NSMenu) throws -> NSMenuItem {
        try XCTUnwrap(tools.items.compactMap(\.submenu).flatMap(\.items).first { $0.title == title }, title)
    }

    func testToolsMenuHasOneSubmenuPerGroupInOrder() throws {
        let textView = makeTextView("abc")
        textView.selectedRange = NSRange(location: 0, length: 3)
        let tools = try submenu(for: textView)
        XCTAssertEqual(tools.items.map(\.title), ["Encode / Decode", "JSON", "Case", "Lines", "Hash", "Convert"])
        func titles(_ group: String) -> [String] {
            tools.items.first { $0.title == group }?.submenu?.items.map { $0.isSeparatorItem ? "-" : $0.title } ?? []
        }
        XCTAssertEqual(titles("Encode / Decode"), [
            "Encode Base64", "Decode Base64", "URL Encode", "URL Decode",
            "Encode HTML Entities", "Decode HTML Entities", "Hex Encode", "Hex Decode",
            "Escape String", "Unescape String", "Unicode Escape", "Unicode Unescape", "-", "Decode JWT…"
        ])
        XCTAssertEqual(titles("JSON"), ["Format JSON", "Minify JSON"])
        XCTAssertEqual(titles("Case"), [
            "UPPERCASE", "lowercase", "Title Case", "camelCase", "PascalCase", "snake_case", "kebab-case",
            "SCREAMING_SNAKE_CASE"
        ])
        XCTAssertEqual(titles("Lines"), [
            "Sort Lines Ascending", "Sort Lines Descending", "Remove Duplicate Lines", "Reverse Lines",
            "Remove Blank Lines", "Trim Trailing Whitespace"
        ])
        XCTAssertEqual(titles("Hash"), ["MD5", "SHA-1", "SHA-256", "SHA-512"])
        XCTAssertEqual(titles("Convert"), [
            "Unix Time to Date", "Date to Unix Time", "Number to Hex", "Number to Binary", "Number to Decimal"
        ])
    }

    func testDecodeJWTFromTheMenuOpensTheSheetWithoutChangingTheDocument() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        let token = IDEJWTTestToken.make(header: #"{"alg":"HS256"}"#, payload: #"{"sub":"1"}"#)
        let textView = makeTextView("token = \(token);")
        textView.selectedRange = NSRange(location: 8, length: token.utf16.count)
        let workspace = IDEWorkspace()
        let context = EditorContextMenuContext(location: 8, selectedRange: textView.selectedRange)
        let tools = try XCTUnwrap(workspace.textToolsContextMenuItems(context: context, textView: textView).first { $0.title == "Tools" }?.submenu)
        let decode = try item(titled: "Decode JWT…", in: tools)
        NSApp.sendAction(try XCTUnwrap(decode.action), to: decode.target, from: decode)
        XCTAssertEqual(workspace.jwtDecoding?.algorithm, "HS256")
        XCTAssertEqual(workspace.jwtDecoding?.anchorOffset, 8 + token.utf16.count)
        XCTAssertEqual(textView.text, "token = \(token);")
    }

    func testInsertJWTAsCommentPutsTheDecodedTokenOnTheLinesAfterIt() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        let workspace = IDEWorkspace()
        workspace.bootstrap() // an editor host needs the adapter that bootstrap() wires
        let textView = workspace.host(for: workspace.workbench.activePaneID).textView
        let token = IDEJWTTestToken.make(header: #"{"alg":"HS256"}"#, payload: #"{"sub":"1"}"#)
        textView.text = "first\ntoken = \(token)\nlast"
        var decoding = try XCTUnwrap(IDEJWTText.decode(token))
        decoding.anchorOffset = ("first\ntoken = " as NSString).length + 3
        workspace.jwtDecoding = decoding

        workspace.insertJWTAsComment(decoding)

        XCTAssertNil(workspace.jwtDecoding, "the sheet closes")
        let lines = textView.text.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "first")
        XCTAssertEqual(lines[1], "token = \(token)")
        XCTAssertTrue(lines[2].hasSuffix("JWT header"), lines[2])
        XCTAssertTrue(textView.text.contains("\"alg\": \"HS256\""))
        XCTAssertEqual(lines.last, "last", "the text after the token is untouched")
    }

    func testInsertJWTAsCommentOnTheLastLine() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        let workspace = IDEWorkspace()
        workspace.bootstrap() // an editor host needs the adapter that bootstrap() wires
        let textView = workspace.host(for: workspace.workbench.activePaneID).textView
        let token = IDEJWTTestToken.make(header: #"{"alg":"HS256"}"#, payload: #"{"sub":"1"}"#)
        textView.text = token
        var decoding = try XCTUnwrap(IDEJWTText.decode(token))
        decoding.anchorOffset = token.utf16.count
        workspace.insertJWTAsComment(decoding)
        XCTAssertTrue(textView.text.hasPrefix(token + "\n"))
        XCTAssertTrue(textView.text.contains("JWT payload"))
    }

    func testInsertionPutsAFreshValueAtEveryCaretInOneUndoStep() {
        let textView = makeTextView("a\nb\nc")
        textView.selectedRanges = [NSRange(location: 1, length: 0), NSRange(location: 3, length: 0), NSRange(location: 4, length: 1)]
        let counter = Counter()
        let insertion = IDETextInsertion(id: "t", title: "T") { counter.next() }
        IDEWorkspace.applyTextInsertion(insertion, in: textView)
        XCTAssertEqual(textView.text, "a1\nb2\n3")
        XCTAssertEqual(textView.selectedRanges, [NSRange(location: 2, length: 0), NSRange(location: 5, length: 0), NSRange(location: 7, length: 0)])
        textView.undoManager?.undo()
        XCTAssertEqual(textView.text, "a\nb\nc")
    }

    func testFormatJSONKeepsTheBlockIndentSelectsTheResultAndUndoesInOneStep() throws {
        let original = "    {\"a\":[1,2]}"
        let textView = makeTextView(original)
        textView.selectedRange = NSRange(location: 4, length: original.utf16.count - 4)
        let item = try item(titled: "Format JSON", in: submenu(for: textView))
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
        let item = try item(titled: "Sort Lines Ascending", in: submenu(for: textView))
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

/// Builds JWT-shaped strings for tests.
enum IDEJWTTestToken {
    static func make(header: String, payload: String, signature: String = "c2ln") -> String {
        func base64URL(_ text: String) -> String {
            Data(text.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(base64URL(header)).\(base64URL(payload)).\(signature)"
    }
}

private final class Counter: @unchecked Sendable {
    private var value = 0
    func next() -> String {
        value += 1
        return String(value)
    }
}
