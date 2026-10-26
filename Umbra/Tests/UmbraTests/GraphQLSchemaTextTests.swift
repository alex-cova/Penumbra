import EditorIntelligence
import Foundation
import XCTest
@testable import Umbra

final class GraphQLSchemaTextTests: XCTestCase {
    func testFullTextRendersDefinitions() {
        let text = GraphQLSchemaText.fullText(for: GraphQLFixtures.schema, source: "https://example.com/graphql")
        XCTAssertTrue(text.contains("# GraphQL schema: https://example.com/graphql"))
        XCTAssertTrue(text.contains("type Query {"))
        XCTAssertTrue(text.contains("me: User"))
        XCTAssertTrue(text.contains("user(id: ID!): User"))
        XCTAssertTrue(text.contains("name(format: String = \"full\"): String"))
        XCTAssertTrue(text.contains("posts(first: Int!, after: String, filter: PostFilter): [Post!]! @deprecated(reason: \"use feed\")"))
        XCTAssertTrue(text.contains("type User implements Node & Entity {"))
        XCTAssertTrue(text.contains("union SearchResult = User | Post"))
        XCTAssertTrue(text.contains("enum Role {"))
        XCTAssertTrue(text.contains("input PostFilter {"))
        XCTAssertTrue(text.contains("since: DateTime = \"2020-01-01\""))
        XCTAssertFalse(text.contains("__"))
        XCTAssertFalse(text.contains("scalar String"))
    }

    func testFullTextOrdersRootsFirst() {
        let text = GraphQLSchemaText.fullText(for: GraphQLFixtures.schema)
        let query = text.range(of: "type Query {")?.lowerBound
        let mutation = text.range(of: "type Mutation {")?.lowerBound
        let post = text.range(of: "type Post {")?.lowerBound
        XCTAssertNotNil(query)
        XCTAssertNotNil(mutation)
        XCTAssertNotNil(post)
        XCTAssertTrue(query! < mutation!)
        XCTAssertTrue(mutation! < post!)
    }

    func testFullTextRoundTripsThroughParser() {
        let schema = GraphQLFixtures.schema
        let reparsed = GraphQLSDLParser.parse(GraphQLSchemaText.fullText(for: schema))
        let names = { (schema: GraphQLSchema) in
            Set(schema.types.keys.filter { !$0.hasPrefix("__") && !GraphQLSchema.builtInScalars.contains($0) })
        }
        XCTAssertEqual(names(reparsed), names(schema))
        XCTAssertEqual(reparsed.queryType, schema.queryType)
    }

    func testExcerptIsBounded() {
        let excerpt = GraphQLSchemaText.excerpt(for: GraphQLFixtures.schema, maxLines: 10)
        let lines = excerpt.components(separatedBy: "\n")
        XCTAssertLessThanOrEqual(lines.count, 10)
        XCTAssertTrue(lines.last?.contains("more type") == true)
        XCTAssertFalse(excerpt.contains("union SearchResult"))
    }

    func testExcerptFitsSmallSchemaWithoutHint() {
        var schema = GraphQLSchema()
        schema.types["Query"] = GraphQLNamedType(
            name: "Query", kind: .object,
            fields: [GraphQLField(name: "me", arguments: [], type: GraphQLTypeRef(name: "String"))]
        )
        schema.finish()
        let excerpt = GraphQLSchemaText.excerpt(for: schema, maxLines: 24)
        XCTAssertTrue(excerpt.contains("me: String"))
        XCTAssertFalse(excerpt.contains("more type"))
    }

    func testEmptySchemaRendersNothing() {
        XCTAssertEqual(GraphQLSchemaText.fullText(for: GraphQLSchema()), "")
        XCTAssertEqual(GraphQLSchemaText.excerpt(for: GraphQLSchema()), "")
    }

    func testPreviewLanguageResolvesToAGrammar() {
        // The schema preview opens untitled with this identifier; a typo would silently
        // highlight as plain text.
        XCTAssertNotNil(IDELanguageSupport.language(forIdentifier: "graphql"))
    }
}

final class HTTPSchemaHoverTests: XCTestCase {
    func testHoverShowsSchemaWithOpenAction() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let schemaURL = directory.appendingPathComponent("schema.graphql")
        try "type Query { me: String }\n".write(to: schemaURL, atomically: true, encoding: .utf8)

        let store = GraphQLSchemaStore(cacheDirectory: nil)
        // Load synchronously: the hover only prefetches in the background, so the first hover of
        // a fresh schema would otherwise still say "loading…".
        _ = try await store.refresh(GraphQLSchemaRequest(url: schemaURL))
        let provider = HTTPSchemaHoverProvider()
        provider.configure(store: store, globals: { [:] })
        let text = "###@scheme:\(schemaURL.absoluteString)\n\nGET https://example.com\n"
        let result = await provider.provide(context: Self.context(text: text, offset: 5))
        let contents = try XCTUnwrap(result?.contents)
        XCTAssertTrue(contents.contains("**GraphQL schema**"))
        XCTAssertTrue(contents.contains("```graphql"))
        XCTAssertTrue(contents.contains("me: String"))
        let action = try XCTUnwrap(result?.actions.first)
        XCTAssertEqual(action.id, HTTPSchemaHoverProvider.openActionID)
        XCTAssertEqual(action.arguments, [schemaURL.absoluteString])
    }

    func testHoverWithoutDirectiveReturnsNil() async {
        let provider = HTTPSchemaHoverProvider()
        provider.configure(store: GraphQLSchemaStore(cacheDirectory: nil), globals: { [:] })
        let result = await provider.provide(
            context: Self.context(text: "GET https://example.com\n", offset: 0)
        )
        XCTAssertNil(result)
    }

    private static func context(text: String, offset: Int) -> HoverContext {
        let snapshot = TextSnapshot(version: 0, text: text)
        let position = TextPosition(line: 0, column: offset, utf16Offset: offset)
        let document = Document(
            id: DocumentID(),
            url: nil,
            displayName: "request.http",
            contentSnapshot: snapshot,
            selection: Selection(range: TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: "http"
        )
        return HoverContext(
            document: document,
            cursor: Cursor(position: position),
            selection: Selection(range: TextRange(start: position, end: position))
        )
    }
}
