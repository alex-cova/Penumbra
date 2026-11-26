import DatabaseKit
import SwiftUI
import XCTest
@testable import Umbra

@MainActor
final class IDEDatabaseVisualizationTests: XCTestCase {
    private func stored(_ columns: [String], _ rows: [[DatabaseValue]]) async throws -> IDEDatabaseVisualizationSource {
        let storage = IDEDatabaseResultStorage()
        try await storage.store.append(rows)
        await storage.store.finish()
        return IDEDatabaseVisualizationSource(storage: storage, columns: columns, rowCount: rows.count, complete: true)
    }

    func testSampleAndLineReductionRetainDistantRowsAndEndpoints() async throws {
        let source = try await stored(["value"], (0..<12_000).map { [.int(Int64($0))] })
        let data = try await IDEDatabaseChartData.load(from: source, settings: .init(kind: .line, y: 0, aggregate: .none))
        XCTAssertEqual(data.sampledRows, 5_000)
        XCTAssertEqual(data.points.count, 1_000)
        XCTAssertTrue(data.reduced)
        XCTAssertEqual(data.points.first?.sourceRow, 0)
        XCTAssertEqual(data.points.last?.sourceRow, 11_999)
        XCTAssertTrue(source.scope(sampleCount: data.sampledRows).hasPrefix("Sample"))
    }

    func testGroupedMedianAndDateGranularityKeepTheFirstSourceRow() async throws {
        let source = try await stored(["date", "value"], [
            [.temporal("2026-11-24", .date), .int(8)],
            [.temporal("2026-11-25", .date), .int(12)],
            [.temporal("2026-11-26", .date), .null],
        ])
        let settings = IDEDatabaseChartSettings(kind: .line, x: 0, y: 1, aggregate: .median, dateUnit: .month)
        let data = try await IDEDatabaseChartData.load(from: source, settings: settings)
        XCTAssertEqual(data.points.count, 1)
        let point = try XCTUnwrap(data.points.first)
        XCTAssertEqual(point.x.label, "2026-11-01T00:00:00Z")
        XCTAssertEqual(point.y, 10)
        XCTAssertEqual(point.sourceRow, 0)
        XCTAssertEqual(point.rowCount, 2)
        XCTAssertEqual(data.omittedRows, 1)
    }

    func testHistogramAndScatterBinsConserveCounts() async throws {
        let source = try await stored(["x", "y"], (0..<1_500).map { [.int(Int64($0 % 7)), .int(Int64($0 % 4))] })
        let scatter = try await IDEDatabaseChartData.load(from: source,
            settings: .init(kind: .scatter, x: 0, y: 1, aggregate: .none))
        XCTAssertTrue(scatter.reduced)
        XCTAssertEqual(scatter.points.count, 28)
        XCTAssertEqual(scatter.points.map(\.rowCount).reduce(0, +), 1_500)
        let histogram = try await IDEDatabaseChartData.load(from: source, settings: .init(kind: .histogram, x: 0))
        XCTAssertEqual(histogram.points.count, 20)
        XCTAssertEqual(histogram.points.map(\.rowCount).reduce(0, +), 1_500)
    }

    func testChartTypesRenderWithTheExportSizedView() async throws {
        let source = try await stored(["x", "value", "series"], [
            [.int(10), .int(5), .text("East")],
            [.int(20), .int(7), .text("West")],
            [.int(30), .int(9), .text("East")],
        ])
        for kind in IDEDatabaseChartKind.allCases {
            let settings = IDEDatabaseChartSettings(kind: kind, x: 0, y: 1, series: 2, aggregate: .sum)
            let data = try await IDEDatabaseChartData.load(from: source, settings: settings)
            XCTAssertFalse(data.points.isEmpty, kind.rawValue)
            let render = ImageRenderer(content: IDEDatabaseChartPlot(settings: settings, points: data.points,
                                                                      xTitle: "X", yTitle: "Value")
                .frame(width: 880, height: 520))
            let image = try XCTUnwrap(render.cgImage, kind.rawValue)
            XCTAssertEqual(image.width, 880, kind.rawValue)
        }
    }

    func testGeometryAcceptsOnlyRecognizedCoordinatesAndSRIDs() async throws {
        let wkb = "0101000000000000000000f03f0000000000000040"
        let ewkb = "0101000020e6100000000000000000f03f0000000000000040"
        let source = try await stored(["geometry"], [
            [.text(#"{"type":"Point","coordinates":[1,2]}"#)],
            [.text("SRID=4326;POINT (1 2)")],
            [.text(ewkb)],
            [.text(wkb)],
            [.text("SRID=3857;POINT (1 2)")],
            [.text(#"{"type":"Point","coordinates":[1,2],"crs":{"properties":{"name":"EPSG:3857"}}}"#)],
            [.text(#"{"type":"Point","coordinates":[1,100]}"#)],
        ])
        let data = try await IDEDatabaseMapData.load(from: source, input: .geometry(0))
        XCTAssertEqual(data.features.map(\.row), [0, 1, 2])
        XCTAssertEqual(data.features.flatMap { $0.shape.coordinates },
                       Array(repeating: try XCTUnwrap(IDEDatabaseMapCoordinate(latitude: 2, longitude: 1)), count: 3))
        XCTAssertEqual(data.unsupportedRows, 3)
        XCTAssertEqual(data.invalidRows, 1)

        let withSRID = try await stored(["geometry", "srid"], [[.text(wkb), .int(4326)], [.text(wkb), .int(3857)]])
        let checked = try await IDEDatabaseMapData.load(from: withSRID, input: .geometry(0, srid: 1))
        XCTAssertEqual(checked.features.map(\.row), [0])
        XCTAssertEqual(checked.unsupportedRows, 1)
    }

    func testCoordinatesAcrossAntimeridianUseANarrowViewport() async throws {
        let source = try await stored(["lat", "lon"], [[.int(42), .int(179)], [.int(43), .int(-179)], [.int(0), .int(181)]])
        let data = try await IDEDatabaseMapData.load(from: source, input: .coordinates(latitude: 0, longitude: 1))
        XCTAssertEqual(data.features.map(\.row), [0, 1])
        XCTAssertEqual(data.invalidRows, 1)
        let projection = try XCTUnwrap(IDEDatabaseMapProjection(features: data.features))
        XCTAssertEqual(projection.region.span.longitudeDelta, 2.4, accuracy: 0.001)
    }

    func testGeneratedServerAggregationUsesQuotedFieldsAndRunsInSQLite() async throws {
        let binding = IDEDatabaseConsoleBinding(connectionID: UUID())
        let statement = #"SELECT 'a' AS "Sales Group", 2 AS amount UNION ALL SELECT 'a', 4;"#
        let query = IDEDatabaseChartQuery(statement: statement, engine: .sqlite, binding: binding)
        let settings = IDEDatabaseChartSettings(x: 0, y: 1, aggregate: .sum)
        let sql = try XCTUnwrap(query.sql(columns: ["Sales Group", "amount"], settings: settings))
        XCTAssertTrue(sql.contains(#"chart_source."Sales Group""#))
        let session = try await SQLiteSession.open(.init(location: .memory))
        let store = ResultStore(columns: [])
        _ = try await session.execute(sql, into: store)
        let rows = try await store.mapRows(in: 0..<1) { $0 }
        XCTAssertEqual(rows, [[.text("a"), .int(6)]])
        await store.close()
        await session.close()
        let write = IDEDatabaseChartQuery(statement: "DELETE FROM sales RETURNING amount", engine: .sqlite, binding: binding)
        XCTAssertNil(try write.sql(columns: ["Sales Group", "amount"], settings: settings))
        XCTAssertNil(try query.sql(columns: ["amount", "amount"], settings: settings))
    }
}
