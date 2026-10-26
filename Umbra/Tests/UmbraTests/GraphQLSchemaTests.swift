import Foundation
import XCTest
@testable import Umbra

enum GraphQLFixtures {
    static let sdl = """
    \"\"\"The root.\"\"\"
    schema { query: Query mutation: Mutation }

    scalar DateTime

    "A user."
    type User implements Node & Entity {
      "The id."
      id: ID!
      name(format: String = "full"): String
      posts(first: Int!, after: String, filter: PostFilter): [Post!]! @deprecated(reason: "use feed")
      role: Role
    }
    interface Node { id: ID! }
    interface Entity { createdAt: DateTime }
    union SearchResult = User | Post
    enum Role { ADMIN USER @deprecated(reason: "gone") }
    input PostFilter { tag: String, since: DateTime = "2020-01-01", nested: PostFilter }
    type Post { id: ID! title: String author: User }
    type Query {
      me: User
      user(id: ID!): User
      search(text: String!): [SearchResult!]!
    }
    type Mutation { createPost(input: PostFilter!): Post }
    extend type User { email: String }
    directive @auth(role: Role = USER) on FIELD_DEFINITION | OBJECT
    """

    static var schema: GraphQLSchema {
        GraphQLSDLParser.parse(sdl)
    }

    /// A trimmed `__schema` answer: `type Query { me: User }`, `type User { id: ID!, tags: [String!] }`.
    static let introspection = """
    {"data":{"__schema":{
      "queryType":{"name":"Query"},"mutationType":null,"subscriptionType":null,
      "types":[
        {"kind":"OBJECT","name":"Query","description":"Root","fields":[
          {"name":"me","description":"The caller","args":[],"type":{"kind":"OBJECT","name":"User","ofType":null},"isDeprecated":false,"deprecationReason":null}
        ],"inputFields":null,"interfaces":[],"enumValues":null,"possibleTypes":null},
        {"kind":"OBJECT","name":"User","description":null,"fields":[
          {"name":"id","description":null,"args":[],"type":{"kind":"NON_NULL","name":null,"ofType":{"kind":"SCALAR","name":"ID","ofType":null}},"isDeprecated":false,"deprecationReason":null},
          {"name":"tags","description":null,"args":[{"name":"first","description":null,"type":{"kind":"SCALAR","name":"Int","ofType":null},"defaultValue":"10"}],
           "type":{"kind":"LIST","name":null,"ofType":{"kind":"NON_NULL","name":null,"ofType":{"kind":"SCALAR","name":"String","ofType":null}}},
           "isDeprecated":true,"deprecationReason":"use labels"}
        ],"inputFields":null,"interfaces":[],"enumValues":null,"possibleTypes":null},
        {"kind":"SCALAR","name":"ID","description":null,"fields":null,"inputFields":null,"interfaces":null,"enumValues":null,"possibleTypes":null}
      ],
      "directives":[{"name":"include","description":"Include","locations":["FIELD"],"args":[{"name":"if","description":null,"type":{"kind":"NON_NULL","name":null,"ofType":{"kind":"SCALAR","name":"Boolean","ofType":null}},"defaultValue":null}]}]
    }}}
    """
}

final class GraphQLSchemaTests: XCTestCase {
    func testSDLRootsAndMergedExtensions() throws {
        let schema = GraphQLFixtures.schema
        XCTAssertEqual(schema.queryType, "Query")
        XCTAssertEqual(schema.mutationType, "Mutation")
        XCTAssertNil(schema.subscriptionType)
        let user = try XCTUnwrap(schema.types["User"])
        XCTAssertEqual(user.kind, .object)
        XCTAssertEqual(user.description, "A user.")
        XCTAssertEqual(user.fields.map(\.name), ["id", "name", "posts", "role", "email"])
        XCTAssertEqual(user.interfaces, ["Node", "Entity"])
    }

    func testSDLFieldsArgumentsAndDeprecation() throws {
        let user = try XCTUnwrap(GraphQLFixtures.schema.types["User"])
        let id = try XCTUnwrap(user.fields.first { $0.name == "id" })
        XCTAssertEqual(id.type.display, "ID!")
        XCTAssertEqual(id.type.name, "ID")
        XCTAssertTrue(id.type.isRequired)
        XCTAssertEqual(id.description, "The id.")

        let posts = try XCTUnwrap(user.fields.first { $0.name == "posts" })
        XCTAssertEqual(posts.type.display, "[Post!]!")
        XCTAssertEqual(posts.type.name, "Post")
        XCTAssertEqual(posts.deprecationReason, "use feed")
        XCTAssertEqual(posts.arguments.map(\.name), ["first", "after", "filter"])
        XCTAssertTrue(posts.arguments[0].isRequired)
        XCTAssertFalse(posts.arguments[1].isRequired)

        let name = try XCTUnwrap(user.fields.first { $0.name == "name" })
        XCTAssertEqual(name.arguments.first?.defaultValue, "\"full\"")
        XCTAssertFalse(name.arguments[0].isRequired)
    }

    func testSDLInterfacesUnionsEnumsInputsAndDirectives() throws {
        let schema = GraphQLFixtures.schema
        XCTAssertEqual(Set(schema.types["Node"]?.possibleTypes ?? []), ["User"])
        XCTAssertEqual(schema.types["SearchResult"]?.possibleTypes, ["User", "Post"])
        XCTAssertEqual(schema.types["Role"]?.enumValues.map(\.name), ["ADMIN", "USER"])
        XCTAssertEqual(schema.types["Role"]?.enumValues.last?.deprecationReason, "gone")
        XCTAssertEqual(schema.types["PostFilter"]?.inputFields.map(\.name), ["tag", "since", "nested"])
        XCTAssertEqual(schema.types["PostFilter"]?.inputFields[1].defaultValue, "\"2020-01-01\"")
        let auth = try XCTUnwrap(schema.directives.first { $0.name == "auth" })
        XCTAssertEqual(auth.locations, ["FIELD_DEFINITION", "OBJECT"])
        XCTAssertEqual(auth.arguments.first?.defaultValue, "USER")
        XCTAssertTrue(schema.directives.contains { $0.name == "skip" })
        XCTAssertTrue(schema.directives.contains { $0.name == "include" })
        XCTAssertNotNil(schema.types["String"])
    }

    func testSDLWithoutASchemaBlockUsesTheDefaultRootNames() {
        let schema = GraphQLSDLParser.parse("type Query { a: Int } type Mutation { b: Int }")
        XCTAssertEqual(schema.queryType, "Query")
        XCTAssertEqual(schema.mutationType, "Mutation")
    }

    func testSDLKeepsWhatItCanReadAroundAnUnreadableDefinition() {
        let schema = GraphQLSDLParser.parse("""
        type Query { a: Int }
        this is not graphql ((
        type Other { b: String }
        """)
        XCTAssertNotNil(schema.types["Query"])
        XCTAssertNotNil(schema.types["Other"])
    }

    func testDescriptionsMayBeBlockStringsWithIndent() {
        let schema = GraphQLSDLParser.parse("""
        type Query {
          \"\"\"
          First line
            indented
          \"\"\"
          a: Int
        }
        """)
        XCTAssertEqual(schema.types["Query"]?.fields.first?.description, "First line\n  indented")
    }

    func testIntrospectionDecode() throws {
        let schema = try GraphQLIntrospection.decode(Data(GraphQLFixtures.introspection.utf8))
        XCTAssertEqual(schema.queryType, "Query")
        let user = try XCTUnwrap(schema.types["User"])
        XCTAssertEqual(user.fields.map(\.name), ["id", "tags"])
        XCTAssertEqual(user.fields[0].type.display, "ID!")
        XCTAssertEqual(user.fields[1].type.display, "[String!]")
        XCTAssertFalse(user.fields[1].type.isRequired)
        XCTAssertEqual(user.fields[1].deprecationReason, "use labels")
        XCTAssertEqual(user.fields[1].arguments.first?.defaultValue, "10")
        XCTAssertEqual(schema.types["Query"]?.fields.first?.description, "The caller")
        XCTAssertTrue(schema.directives.contains { $0.name == "include" })
        XCTAssertTrue(schema.directives.contains { $0.name == "skip" })
    }

    func testIntrospectionAcceptsABareSchemaObjectAndReportsServerErrors() throws {
        let bare = """
        {"__schema":{"queryType":{"name":"Query"},"types":[{"kind":"OBJECT","name":"Query","fields":[],"interfaces":[]}],"directives":[]}}
        """
        XCTAssertNotNil(try GraphQLIntrospection.decode(Data(bare.utf8)).types["Query"])
        XCTAssertThrowsError(try GraphQLIntrospection.decode(Data(#"{"errors":[{"message":"Introspection is disabled"}]}"#.utf8))) {
            XCTAssertEqual($0 as? GraphQLIntrospection.DecodeError, .server("Introspection is disabled"))
        }
        XCTAssertThrowsError(try GraphQLIntrospection.decode(Data("<html>".utf8))) {
            XCTAssertEqual($0 as? GraphQLIntrospection.DecodeError, .notJSON)
        }
    }

    func testIntrospectionQueryNestsTypeRefsSevenDeep() {
        XCTAssertEqual(GraphQLIntrospection.query.components(separatedBy: "ofType {").count - 1, 7)
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: GraphQLIntrospection.requestBody))
    }

    func testLexerSkipsCommentsAndCommasAndDecodesStrings() {
        let output = GraphQLLexer.lex("{ a(b: \"x\\ny\", c: 1.5e3) # note\n d }")
        let kinds = output.tokens.map(\.text)
        XCTAssertEqual(kinds, ["{", "a", "(", "b", ":", "x\ny", "c", ":", "1.5e3", ")", "d", "}"])
        XCTAssertFalse(output.endsInComment)
        XCTAssertTrue(GraphQLLexer.lex("{ a # open").endsInComment)
    }
}
