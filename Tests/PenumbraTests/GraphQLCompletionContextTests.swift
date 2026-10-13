import Foundation
import XCTest
@testable import Umbra

final class GraphQLCompletionContextTests: XCTestCase {
    private let schema = GraphQLFixtures.schema

    private func site(_ text: String) -> GraphQLCompletionSite? {
        GraphQLCompletionContext.site(in: text, schema: schema)
    }

    func testTopLevelOffersOperationKeywords() {
        XCTAssertEqual(site(""), .operationKeyword)
        XCTAssertEqual(site("que"), .operationKeyword)
        XCTAssertEqual(site("query { me { id } }\n"), .operationKeyword)
        XCTAssertNil(site("query "))
    }

    func testSelectionSetsFollowFieldTypes() {
        XCTAssertEqual(site("{ "), .selection(typeName: "Query", variables: []))
        XCTAssertEqual(site("{ me { "), .selection(typeName: "User", variables: []))
        XCTAssertEqual(site("{ me { na"), .selection(typeName: "User", variables: []))
        XCTAssertEqual(site("{ me { id } "), .selection(typeName: "Query", variables: []))
        XCTAssertEqual(site("query { me { posts(first: 3) { "), .selection(typeName: "Post", variables: []))
        XCTAssertEqual(site("mutation { createPost(input: {}) { "), .selection(typeName: "Post", variables: []))
        XCTAssertEqual(site("{ me { alias: "), .selection(typeName: "User", variables: []))
        XCTAssertEqual(site("{ me { posts { writer: author { "), .selection(typeName: "User", variables: []))
    }

    func testAliasedFieldResolvesByItsRealName() {
        XCTAssertEqual(site("{ first: me { "), .selection(typeName: "User", variables: []))
        XCTAssertEqual(site("{ first: me { latest: posts { "), .selection(typeName: "Post", variables: []))
    }

    func testArgumentNamesExcludeThoseAlreadyGiven() {
        XCTAssertEqual(
            site("query { user("),
            .argumentName(owner: .field(parentType: "Query", name: "user"), used: [])
        )
        XCTAssertEqual(
            site("{ me { posts(first: 1, "),
            .argumentName(owner: .field(parentType: "User", name: "posts"), used: ["first"])
        )
        XCTAssertEqual(
            site("{ me { posts(first: 1, filter: {tag: \"x\"}, "),
            .argumentName(owner: .field(parentType: "User", name: "posts"), used: ["first", "filter"])
        )
    }

    func testArgumentValuesKnowTheExpectedType() {
        XCTAssertEqual(site("query { user(id: "), .value(typeName: "ID", variables: []))
        XCTAssertEqual(site("{ me { posts(first: 1, after: "), .value(typeName: "String", variables: []))
        XCTAssertEqual(site("{ me { name(format: "), .value(typeName: "String", variables: []))
    }

    func testInputObjectFieldsAndNesting() {
        XCTAssertEqual(
            site("{ me { posts(first: 1, filter: { "),
            .objectField(typeName: "PostFilter", used: [])
        )
        XCTAssertEqual(
            site("{ me { posts(first: 1, filter: { tag: \"x\", "),
            .objectField(typeName: "PostFilter", used: ["tag"])
        )
        XCTAssertEqual(
            site("{ me { posts(first: 1, filter: { nested: { "),
            .objectField(typeName: "PostFilter", used: [])
        )
        XCTAssertEqual(
            site("{ me { posts(first: 1, filter: { since: "),
            .value(typeName: "DateTime", variables: [])
        )
        XCTAssertEqual(
            site("mutation { createPost(input: { "),
            .objectField(typeName: "PostFilter", used: [])
        )
    }

    func testListValuesKeepTheElementType() {
        XCTAssertEqual(site("{ me { posts(first: [1, "), .value(typeName: "Int", variables: []))
        // An object where the schema has a string: nothing to offer, not a wrong type.
        XCTAssertNil(site("{ me { posts(first: 1, filter: { tag: [ { "))
    }

    func testInlineFragmentsAndSpreads() {
        XCTAssertEqual(site("{ search(text: \"a\") { ... "), .spread(parentType: "SearchResult"))
        XCTAssertEqual(site("{ search(text: \"a\") { ... on "), .typeCondition(parent: "SearchResult"))
        XCTAssertEqual(site("{ search(text: \"a\") { ... on Us"), .typeCondition(parent: "SearchResult"))
        XCTAssertEqual(site("{ search(text: \"a\") { ... on User { "), .selection(typeName: "User", variables: []))
        XCTAssertEqual(
            site("{ search(text: \"a\") { ... on User { posts { ... on Post { "),
            .selection(typeName: "Post", variables: [])
        )
        XCTAssertEqual(site("{ me { ... @include(if: true) { "), .selection(typeName: "User", variables: []))
        XCTAssertEqual(site("{ me { ...UserParts "), .selection(typeName: "User", variables: []))
    }

    func testFragmentDefinitions() {
        XCTAssertEqual(site("fragment UserParts on "), .typeCondition(parent: nil))
        XCTAssertEqual(site("fragment UserParts on User { "), .selection(typeName: "User", variables: []))
        XCTAssertEqual(site("fragment UserParts on User { id }\nquery { me { ...UserParts } }\n"), .operationKeyword)
    }

    func testVariableDefinitionsAndUsage() {
        XCTAssertEqual(site("query Q($id: "), .variableType)
        XCTAssertEqual(site("query Q($id: ID!, $tags: ["), .variableType)
        XCTAssertNil(site("query Q($id: ID! = "))
        XCTAssertEqual(
            site("query Q($id: ID!, $n: Int) { user(id: "),
            .value(typeName: "ID", variables: ["id", "n"])
        )
        XCTAssertEqual(
            site("query Q($id: ID!) { user(id: $id) { "),
            .selection(typeName: "User", variables: ["id"])
        )
    }

    func testDirectivesAfterAt() {
        XCTAssertEqual(site("{ me { name @"), .directive)
        XCTAssertEqual(site("{ me { name @inc"), .directive)
        XCTAssertEqual(site("query Q @"), .directive)
    }

    func testDirectiveArguments() {
        XCTAssertEqual(
            site("{ me { name @include("),
            .argumentName(owner: .directive(name: "include"), used: [])
        )
        XCTAssertEqual(site("{ me { name @include(if: "), .value(typeName: "Boolean", variables: []))
        XCTAssertEqual(site("{ me { name @include(if: true) "), .selection(typeName: "User", variables: []))
    }

    func testNothingInsideStringsCommentsOrTheVariablesJSON() {
        XCTAssertNil(site("{ user(id: \"ab"))
        XCTAssertNil(site("{ user(id: \"ab\""))
        XCTAssertNil(site("{ me { # a comment"))
        XCTAssertNil(site("query { me { id } }\n\n{ \"id\": "))
        XCTAssertNil(site("query { me { id } }\n\n{\n  \"id\": 1,\n  \""))
    }

    func testUnknownTypesGiveNothing() {
        XCTAssertNil(site("{ nope { "))
        // The value's type is unknown, so only what needs none is offered.
        XCTAssertEqual(site("{ nope(a: "), .value(typeName: nil, variables: []))
    }

    func testUnbalancedClosersDoNotCrash() {
        XCTAssertEqual(site("} } ) ] "), .operationKeyword)
        _ = site("{ ( [ { ( ")
    }
}
