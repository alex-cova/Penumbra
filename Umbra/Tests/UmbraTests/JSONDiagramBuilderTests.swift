import CoreGraphics
import XCTest
@testable import Umbra

/// JSON text becomes a diagram: key order, paths, the box cap, and parse errors.
final class JSONDiagramBuilderTests: XCTestCase {
    func testObjectKeepsSourceKeyOrder() throws {
        let built = JSONDiagramBuilder.build(
            text: #"{"z": 1, "a": 2, "m": {"q": true, "b": null}}"#,
            title: "sample"
        )
        XCTAssertNil(built.failure)
        XCTAssertNil(built.notice)
        let root = try node(built, "$")
        XCTAssertEqual(root.kind, .jsonObject)
        XCTAssertEqual(root.title, "sample")
        XCTAssertEqual(root.subtitle, "object · 3")
        XCTAssertEqual(childTitles(built, of: "$"), ["z", "a", "m"])

        let nested = try node(built, "$.m")
        XCTAssertEqual(nested.kind, .jsonObject)
        XCTAssertEqual(nested.subtitle, "object · 2")
        XCTAssertEqual(childTitles(built, of: "$.m"), ["q", "b"])
        XCTAssertEqual(try node(built, "$.m.q").subtitle, "true")
        XCTAssertEqual(try node(built, "$.m.b").kind, .jsonValue)
        XCTAssertEqual(try node(built, "$.m.b").subtitle, "null")
        XCTAssertEqual(try node(built, "$.z").subtitle, "1")
    }

    func testArrayIndexesAndPrimitives() throws {
        let built = JSONDiagramBuilder.build(
            text: #"{"tags": ["a", true], "n": 1.5e+2}"#,
            title: "doc"
        )
        XCTAssertNil(built.failure)
        XCTAssertEqual(try node(built, "$.tags").kind, .jsonArray)
        XCTAssertEqual(try node(built, "$.tags").subtitle, "array · 2")
        XCTAssertEqual(try node(built, "$.tags[0]").title, "[0]")
        XCTAssertEqual(try node(built, "$.tags[0]").subtitle, "\"a\"")
        XCTAssertEqual(try node(built, "$.tags[1]").subtitle, "true")
        XCTAssertEqual(try node(built, "$.n").subtitle, "1.5e+2")
        let element = try node(built, "$.tags[0]")
        let edge = try XCTUnwrap(built.document.edges.first { $0.destinationID == element.id })
        XCTAssertEqual(edge.kind, .containment)
        XCTAssertEqual(built.document.node(id: edge.sourceID)?.key, "$.tags")
    }

    func testAStringFileIsOneBoxNamedForTheFile() throws {
        let built = JSONDiagramBuilder.build(text: "\"hello\"", title: "greet")
        XCTAssertEqual(built.document.nodes.count, 1)
        XCTAssertEqual(built.document.edges.count, 0)
        let root = try node(built, "$")
        XCTAssertEqual(root.kind, .jsonValue)
        XCTAssertEqual(root.title, "greet")
        XCTAssertEqual(root.subtitle, "\"hello\"")
    }

    func testEscapesAndAQuotedKey() throws {
        let built = JSONDiagramBuilder.build(
            text: #"{"a.b": "hi\n\"x\"", "ok": "\u0041\uD83D\uDE00"}"#,
            title: "esc"
        )
        XCTAssertNil(built.failure)
        XCTAssertEqual(try node(built, "$[\"a.b\"]").title, "a.b")
        XCTAssertEqual(try node(built, "$[\"a.b\"]").subtitle, "\"hi\\n\\\"x\\\"\"")
        XCTAssertEqual(try node(built, "$.ok").subtitle, "\"A😀\"")
    }

    func testALongStringIsCut() throws {
        let value = String(repeating: "x", count: JSONDiagramBuilder.maximumValueLength + 5)
        let built = JSONDiagramBuilder.build(text: "\"\(value)\"", title: "long")
        let subtitle = try node(built, "$").subtitle
        XCTAssertTrue(subtitle.hasSuffix("…\""))
        XCTAssertEqual(subtitle.count, JSONDiagramBuilder.maximumValueLength + 3)
    }

    func testDuplicateKeyKeepsTheLastValue() throws {
        let built = JSONDiagramBuilder.build(text: #"{"a": {"b": 1}, "a": 3, "z": 0}"#, title: "dup")
        XCTAssertNil(built.failure)
        XCTAssertEqual(childTitles(built, of: "$"), ["a", "z"])
        XCTAssertEqual(try node(built, "$.a").subtitle, "3")
        XCTAssertNil(built.document.nodes.first { $0.key == "$.a.b" })
    }

    func testTheSameTextKeepsTheSameIds() {
        let text = #"{"user": {"name": "Ada"}, "tags": [1]}"#
        let first = JSONDiagramBuilder.build(text: text, title: "t")
        let second = JSONDiagramBuilder.build(text: text, title: "t")
        XCTAssertEqual(first.document.nodes.map(\.id), second.document.nodes.map(\.id))
        XCTAssertEqual(first.document.edges.map(\.id), second.document.edges.map(\.id))
        XCTAssertEqual(first.document.nodes.first { $0.key == "$.user.name" }?.id, IDEDiagramIdentity.id(for: "node:$.user.name"))
    }

    func testTheBoxCapOmitsTheRest() throws {
        let body = (0..<500).map(String.init).joined(separator: ",")
        let built = JSONDiagramBuilder.build(text: "[\(body)]", title: "nums")
        let omitted = 501 - JSONDiagramBuilder.maximumNodes
        XCTAssertEqual(built.document.nodes.count, JSONDiagramBuilder.maximumNodes)
        XCTAssertEqual(built.notice, "Showing \(JSONDiagramBuilder.maximumNodes) values; \(omitted) more omitted.")
        XCTAssertNil(built.failure)
        XCTAssertEqual(try node(built, "$").subtitle, "array · 500")
        XCTAssertNotNil(built.document.nodes.first { $0.key == "$[\(JSONDiagramBuilder.maximumNodes - 2)]" })
        XCTAssertNil(built.document.nodes.first { $0.key == "$[\(JSONDiagramBuilder.maximumNodes - 1)]" })
    }

    func testEmptyAndInvalidJSONFail() {
        XCTAssertEqual(JSONDiagramBuilder.build(text: "", title: "e").failure, "This file is empty.")
        XCTAssertEqual(JSONDiagramBuilder.build(text: " \n\t", title: "e").failure, "This file is empty.")
        XCTAssertEqual(JSONDiagramBuilder.build(text: "\u{feff}", title: "e").failure, "This file is empty.")
        let broken = JSONDiagramBuilder.build(text: "{", title: "e")
        XCTAssertTrue(broken.document.nodes.isEmpty)
        XCTAssertEqual(broken.failure, "Invalid JSON at line 1, column 2: Expected an object key")
        let extra = JSONDiagramBuilder.build(text: "true false", title: "e")
        XCTAssertTrue(extra.failure?.contains("line 1") == true)
    }

    func testContainmentHasNoArrow() {
        let route = [CGPoint(x: 0, y: 0), CGPoint(x: 80, y: 40)]
        let geometry = IDEDiagramEdgeMarkers.geometry(kind: .containment, route: route, size: 10)
        XCTAssertTrue(geometry.shapes.isEmpty)
        XCTAssertEqual(geometry.line, route)
        XCTAssertFalse(IDEDiagramEdgeKind.containment.isDashed)
        XCTAssertFalse(IDEDiagramEdgeKind.containment.ranksDestinationFirst)
    }

    func testTreeLayoutPutsTheParentAboveItsChild() throws {
        let built = JSONDiagramBuilder.build(text: #"{"a": 1}"#, title: "t")
        let laid = IDEDiagramLayoutEngine.laidOut(built.document, kind: .tree)
        let root = try XCTUnwrap(laid.nodes.first { $0.key == "$" })
        let child = try XCTUnwrap(laid.nodes.first { $0.key == "$.a" })
        XCTAssertLessThan(root.frame.midY, child.frame.midY)
    }

    func testJSONPreviewIsNotAClassOrGradleDiagram() {
        let request = IDEDiagramRequest.jsonPreview(title: "package")
        XCTAssertEqual(request.title, "package")
        XCTAssertEqual(request.symbolName, "curlybraces")
        XCTAssertEqual(request.id, "json:preview")
        XCTAssertTrue(request.isJSONPreview)
        XCTAssertFalse(request.isClassDiagram)
        XCTAssertFalse(request.isGradleDiagram)
        XCTAssertTrue(IDEDiagramRequest.gradleModules.isGradleDiagram)
        XCTAssertFalse(IDEDiagramNodeKind.jsonObject.isType)
        XCTAssertFalse(IDEDiagramNodeKind.jsonArray.isType)
        XCTAssertFalse(IDEDiagramNodeKind.jsonValue.isType)
    }

    private func node(_ built: JSONDiagramBuild, _ key: String) throws -> IDEDiagramNode {
        try XCTUnwrap(built.document.nodes.first { $0.key == key })
    }

    private func childTitles(_ built: JSONDiagramBuild, of key: String) -> [String] {
        guard let parent = built.document.nodes.first(where: { $0.key == key }) else { return [] }
        return built.document.edges.filter { $0.sourceID == parent.id }.compactMap { edge in
            built.document.node(id: edge.destinationID)?.title
        }
    }
}
