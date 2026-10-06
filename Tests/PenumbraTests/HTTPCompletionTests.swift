import EditorIntelligence
import XCTest
@testable import Umbra

final class HTTPCompletionTests: XCTestCase {
    func testTemplateOffersFileVariablesFunctionsAndGlobals() async throws {
        let text = """
        @jwt = headerValue
        GET {{
        """
        let provider = HTTPCompletionProvider()
        provider.setGlobals { ["auth_token": "secret-value", "jwt": "ignored"] }
        let context = makeHTTPContext(text)
        XCTAssertEqual(context.prefix, "")
        XCTAssertTrue(provider.isPrimary(for: context))
        let items = await provider.provide(context: context)
        let jwt = try XCTUnwrap(items.first { $0.label == "jwt" })
        XCTAssertEqual(jwt.insertText, "jwt}}")
        XCTAssertEqual(jwt.detail, "headerValue")
        XCTAssertEqual(items.filter { $0.label == "jwt" }.count, 1)
        XCTAssertTrue(items.contains { $0.label == "auth_token" && $0.detail == "secret-value" })
        XCTAssertTrue(items.contains { $0.filterText == "$random.integer()" && $0.labelDetail == "(from, to)" })
        XCTAssertTrue(items.contains { $0.label == "$random.uuid" && $0.insertText == "$random.uuid}}" })
    }

    func testDottedFunctionPrefixKeepsTheWholeToken() async throws {
        let text = "GET {{$random.i"
        let context = makeHTTPContext(text)
        XCTAssertEqual(context.prefix, "$random.i")
        XCTAssertFalse(context.isMemberAccess)
        let engine = CompletionEngine(providers: [HTTPCompletionProvider()], debounceInterval: 0)
        let results = try await engine.complete(context: context)
        XCTAssertTrue(results.contains { $0.label == "$random.integer" })
        XCTAssertFalse(results.contains { $0.label == "$timestamp" })
    }

    func testClosingBracesAreNotDoubled() async {
        let text = "GET {{jw}}"
        let caret = ("GET {{jw" as NSString).length
        let context = makeHTTPContext(text, caret: caret)
        let items = await HTTPCompletionProvider().provide(context: context)
        XCTAssertEqual(items.first { $0.label == "$uuid" }?.insertText, "$uuid")
    }

    func testMethodHeaderAuthAndFlagSuggestions() async {
        let provider = HTTPCompletionProvider()

        let method = makeHTTPContext("G")
        XCTAssertEqual(HTTPCompletion.site(in: "G", caretUTF16: 1), .method)
        let methods = await provider.provide(context: method)
        XCTAssertEqual(methods.first { $0.label == "GET" }?.insertText, "GET ")

        let headers = "GET https://example.com\nAcc"
        XCTAssertEqual(HTTPCompletion.site(in: headers, caretUTF16: (headers as NSString).length), .headerName)
        let headerItems = await provider.provide(context: makeHTTPContext(headers))
        XCTAssertEqual(headerItems.first { $0.label == "Accept" }?.insertText, "Accept: ")

        let authorization = "GET https://example.com\nAuthorization: "
        XCTAssertEqual(
            HTTPCompletion.site(in: authorization, caretUTF16: (authorization as NSString).length),
            .authorization
        )
        let schemes = await provider.provide(context: makeHTTPContext(authorization))
        XCTAssertEqual(Set(schemes.map(\.label)), Set(["Basic", "Bearer", "Digest"]))

        let media = "GET https://example.com\nContent-Type: app"
        let types = await provider.provide(context: makeHTTPContext(media))
        XCTAssertEqual(types.first { $0.label == "application/json" }?.insertText, "application/json")

        let typed = "GET https://example.com\nContent-Type: application/"
        XCTAssertNil(HTTPCompletion.site(in: typed, caretUTF16: (typed as NSString).length))

        let flag = "# @"
        XCTAssertEqual(HTTPCompletion.site(in: flag, caretUTF16: (flag as NSString).length), .directive)
        let flags = await provider.provide(context: makeHTTPContext(flag))
        XCTAssertEqual(Set(flags.map(\.label)), Set(["no-redirect", "no-cookie-jar", "no-auto-encoding"]))
    }

    func testJSONBodyIsNotAPrimaryHTTPSite() async {
        let text = """
        POST https://example.com
        Content-Type: application/json

        {
          "value": "con
        """
        let provider = HTTPCompletionProvider()
        let context = makeHTTPContext(text)
        XCTAssertNil(HTTPCompletion.site(in: text, caretUTF16: (text as NSString).length))
        XCTAssertFalse(provider.isPrimary(for: context))
        let items = await provider.provide(context: context)
        XCTAssertTrue(items.isEmpty)
    }

    func testSuggestionsFollowTheClosingBrace() {
        let text = "POST https://example.com\n\n{\n  \"a\": 1\n}\n"
        XCTAssertEqual(HTTPCompletion.site(in: text, caretUTF16: (text as NSString).length), .method)
    }

    func testHTTPFilesDoNotOfferJavaScriptSnippets() async {
        let provider = SnippetCompletionProvider(excludedLanguageIdentifiers: ["java", "http"])
        let items = await provider.provide(context: makeHTTPContext("fu"))
        XCTAssertTrue(items.isEmpty)
    }

    func testOtherLanguagesAreNotClaimed() {
        let context = makeHTTPContext("GET {{", language: "java")
        XCTAssertFalse(HTTPCompletionProvider().isPrimary(for: context))
    }
}

private func makeHTTPContext(_ text: String, caret: Int? = nil, language: String = "http") -> CompletionContext {
    let offset = caret ?? (text as NSString).length
    let position = TextPosition(line: 0, column: offset, utf16Offset: offset)
    let document = Document(
        id: DocumentID(),
        url: nil,
        displayName: "request.http",
        contentSnapshot: TextSnapshot(version: 0, text: text),
        selection: Selection(range: TextRange(start: position, end: position)),
        cursor: Cursor(position: position),
        viewport: Viewport(x: 0, y: 0, width: 800, height: 600),
        languageIdentifier: language
    )
    return makeCompletionContext(document: document, trigger: .manual)
}
