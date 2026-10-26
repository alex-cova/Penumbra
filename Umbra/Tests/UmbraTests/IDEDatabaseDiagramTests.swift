import DatabaseKit
import XCTest
@testable import Umbra

final class IDEDatabaseDiagramTests: XCTestCase {
    func testTablesBecomeNodesWithColumns() {
        let document = IDEDatabaseDiagram.document(
            title: "shop Schema",
            tables: ["users", "orders"],
            columns: [
                "users": [
                    SQLColumn(name: "id", declaredType: "integer", isPrimaryKey: true, isNotNull: true),
                    SQLColumn(name: "name", declaredType: "text", isPrimaryKey: false, isNotNull: false),
                ],
                "orders": [],
            ],
            foreignKeys: []
        )
        XCTAssertEqual(document.nodes.map(\.title), ["users", "orders"])
        XCTAssertTrue(document.nodes.allSatisfy { $0.kind == .table })
        XCTAssertEqual(document.nodes[0].attributes, ["id: integer PK", "name: text"])
        XCTAssertTrue(document.edges.isEmpty)
    }

    func testForeignKeysBecomeEdgesOnlyBetweenKnownTables() {
        let document = IDEDatabaseDiagram.document(
            title: "shop Schema",
            tables: ["users", "orders"],
            columns: ["users": [], "orders": []],
            foreignKeys: [
                SQLForeignKey(fromTable: "orders", fromColumn: "user_id", toTable: "users", toColumn: "id"),
                SQLForeignKey(fromTable: "orders", fromColumn: "item_id", toTable: "items", toColumn: "id"),
            ]
        )
        XCTAssertEqual(document.edges.count, 1)
        XCTAssertEqual(document.edges[0].label, "user_id")
        let ids = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id, $0.title) })
        XCTAssertEqual(ids[document.edges[0].sourceID], "orders")
        XCTAssertEqual(ids[document.edges[0].destinationID], "users")
    }

    func testRequestRoundTripsTheConnectionID() {
        let id = UUID()
        let connection = DatabaseConnection(id: id, name: "shop", engine: .postgres)
        let request = IDEDatabaseDiagram.request(connection: connection)
        XCTAssertEqual(IDEDatabaseDiagram.connectionID(from: request), id)
        XCTAssertNil(IDEDatabaseDiagram.connectionID(from: IDEDiagramRequest(
            id: "classes:foo", title: "", symbolName: "", presentation: .classes
        )))
    }
}
