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

func makeHTTPContext(_ text: String, caret: Int? = nil, language: String = "http") -> CompletionContext {
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

// MARK: - GraphQL schema completion

final class HTTPGraphQLCompletionTests: XCTestCase {
    private func schemaFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("graphql-http-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("schema.graphql")
        try GraphQLFixtures.sdl.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// A provider whose store has already read the file's schema, so a completion needs no network.
    private func provider(for schema: URL) async throws -> HTTPCompletionProvider {
        let store = GraphQLSchemaStore(cacheDirectory: nil)
        _ = try await store.refresh(GraphQLSchemaRequest(url: schema))
        let provider = HTTPCompletionProvider()
        provider.setSchemaStore(store)
        return provider
    }

    private func document(schema: URL, body: String) -> String {
        """
        ###@scheme:\(schema.path)
        GRAPHQL https://api.test/graphql

        \(body)
        """
    }

    func testFieldsComeFromTheSchemaOfTheDirective() async throws {
        let schema = try schemaFile()
        let provider = try await provider(for: schema)
        let text = document(schema: schema, body: "{ me { ")
        XCTAssertEqual(HTTPCompletion.site(in: text, caretUTF16: (text as NSString).length), .graphQL)
        let context = makeHTTPContext(text)
        XCTAssertTrue(provider.isPrimary(for: context))
        let items = await provider.provide(context: context)
        XCTAssertEqual(
            Set(items.map(\.label)),
            ["id", "name", "posts", "role", "email", "__typename"]
        )
        let posts = try XCTUnwrap(items.first { $0.label == "posts" })
        XCTAssertEqual(posts.detail, "[Post!]!")
        XCTAssertEqual(posts.insertText, "posts()")
        XCTAssertEqual(posts.caretOffset, "posts(".count)
        XCTAssertTrue(posts.isDeprecated)
        XCTAssertEqual(items.first { $0.label == "id" }?.detail, "ID!")
        XCTAssertEqual(items.first { $0.label == "id" }?.documentation, "The id.")
        XCTAssertEqual(items.first { $0.label == "name" }?.insertText, "name")
    }

    func testNestedClosingBracesKeepTheCaretInsideTheBody() async throws {
        let schema = try schemaFile()
        let provider = try await provider(for: schema)
        let body = """
        query {
          me {
            posts(first: 1) {
              title
            }

        """
        let text = document(schema: schema, body: body)
        let items = await provider.provide(context: makeHTTPContext(text))
        XCTAssertTrue(items.contains { $0.label == "email" }, "Back inside `me`, after the inner brace: \(items.map(\.label))")
        XCTAssertFalse(items.contains { $0.label == "GET" })
    }

    func testArgumentsAndEnumValues() async throws {
        let schema = try schemaFile()
        let provider = try await provider(for: schema)

        let names = await provider.provide(context: makeHTTPContext(document(schema: schema, body: "{ me { posts(first: 1, ")))
        XCTAssertEqual(Set(names.map(\.label)), ["after", "filter"])
        XCTAssertEqual(names.first { $0.label == "after" }?.insertText, "after: ")

        let fields = await provider.provide(context: makeHTTPContext(document(schema: schema, body: "{ me { posts(first: 1, filter: { ")))
        XCTAssertEqual(Set(fields.map(\.label)), ["tag", "since", "nested"])
    }

    func testEnumValuesVariablesAndTheVariablesJSON() async throws {
        let schema = try schemaFile()
        let provider = try await provider(for: schema)

        let roles = await provider.provide(
            context: makeHTTPContext(document(schema: schema, body: "{ me { id @auth(role: "))
        )
        XCTAssertTrue(roles.contains { $0.label == "ADMIN" && $0.kind == .enumMember })
        XCTAssertTrue(roles.contains { $0.label == "USER" })

        let ids = await provider.provide(
            context: makeHTTPContext(document(schema: schema, body: "query ($id: ID!) { user(id: "))
        )
        XCTAssertTrue(ids.contains { $0.label == "$id" && $0.insertText == "$id" })
        XCTAssertTrue(ids.contains { $0.label == "null" })

        // After the operation, a JSON object is the variables: not GraphQL.
        let variables = await provider.provide(
            context: makeHTTPContext(document(schema: schema, body: "query ($r: Role) { me { id } }\n\n{ \"r\": "))
        )
        XCTAssertTrue(variables.isEmpty)
    }

    func testTypeConditionsAndVariableTypes() async throws {
        let schema = try schemaFile()
        let provider = try await provider(for: schema)
        let conditions = await provider.provide(
            context: makeHTTPContext(document(schema: schema, body: "{ search(text: \"a\") { ... on "))
        )
        XCTAssertEqual(Set(conditions.map(\.label)), ["User", "Post", "SearchResult"])

        let types = await provider.provide(context: makeHTTPContext(document(schema: schema, body: "query ($id: ")))
        XCTAssertTrue(types.contains { $0.label == "ID" })
        XCTAssertTrue(types.contains { $0.label == "PostFilter" })
        XCTAssertFalse(types.contains { $0.label == "User" })
    }

    func testWithoutADirectiveNothingChangesForBodies() async throws {
        let text = "GRAPHQL https://api.test/graphql\n\n{ me { "
        XCTAssertNil(HTTPCompletion.site(in: text, caretUTF16: (text as NSString).length))
        let provider = HTTPCompletionProvider()
        XCTAssertFalse(provider.isPrimary(for: makeHTTPContext(text)))
    }

    func testAJSONBodyIsNotGraphQLEvenWithADirective() async throws {
        let schema = try schemaFile()
        let text = """
        ###@scheme:\(schema.path)
        POST https://api.test/users
        Content-Type: application/json

        {
          "name":
        """
        XCTAssertNil(HTTPCompletion.site(in: text, caretUTF16: (text as NSString).length))
    }

    func testSchemaNotLoadedYetReturnsNothingAndFallsBack() async throws {
        let schema = try schemaFile()
        let provider = HTTPCompletionProvider()
        provider.setSchemaStore(GraphQLSchemaStore(cacheDirectory: nil))
        let items = await provider.provide(context: makeHTTPContext(document(schema: schema, body: "{ me { ")))
        XCTAssertTrue(items.isEmpty)
    }

    func testRequestLinesAndHeadersStillCompleteAfterANestedBody() {
        // The region scan counts brackets now; a request after a body must still be a request.
        let text = """
        POST https://api.test/a
        Content-Type: application/json

        {
          "a": { "b": 1 }
        }

        GET https://api.test/b
        Acc
        """
        XCTAssertEqual(HTTPCompletion.site(in: text, caretUTF16: (text as NSString).length), .headerName)
        let between = """
        POST https://api.test/a

        {
          "a": {
            "b": 1
          }
        }
        G
        """
        XCTAssertEqual(HTTPCompletion.site(in: between, caretUTF16: (between as NSString).length), .method)
    }
}
