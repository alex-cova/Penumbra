import DatabaseKit
import Foundation

struct IDEDatabaseMapCoordinate: Equatable, Sendable {
    let latitude: Double
    let longitude: Double

    init?(latitude: Double, longitude: Double) {
        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        self.latitude = latitude
        self.longitude = longitude
    }
}

struct IDEDatabaseMapData: Sendable {
    enum Input: Equatable, Sendable {
        case coordinates(latitude: Int, longitude: Int)
        case geometry(Int, srid: Int? = nil)
    }

    enum Shape: Sendable {
        case points([IDEDatabaseMapCoordinate])
        case line([IDEDatabaseMapCoordinate])
        case polygon([[IDEDatabaseMapCoordinate]])

        var coordinates: [IDEDatabaseMapCoordinate] {
            switch self {
            case .points(let points), .line(let points): points
            case .polygon(let rings): rings.flatMap { $0 }
            }
        }
    }

    struct Feature: Identifiable, Sendable {
        let id: Int
        let row: Int
        let shape: Shape
    }

    private enum Read: Sendable {
        case shapes([Shape])
        case invalid, unsupportedCRS, tooLarge
    }

    let features: [Feature]
    let sampledRows: Int
    let invalidRows: Int
    let unsupportedRows: Int
    let omittedForSize: Int

    static func load(from source: IDEDatabaseVisualizationSource, input: Input) async throws -> Self {
        let limit: Int
        switch input {
        case .coordinates: limit = IDEDatabaseChartData.markLimit
        case .geometry: limit = 256
        }
        let samples = try await source.sample(limit: limit) { row in
            switch input {
            case .coordinates(let lat, let lon):
                guard row.indices.contains(lat), row.indices.contains(lon),
                      let latitude = numericCoordinate(row[lat]), let longitude = numericCoordinate(row[lon]),
                      let coordinate = IDEDatabaseMapCoordinate(latitude: latitude, longitude: longitude) else {
                    return Read.invalid
                }
                return .shapes([.points([coordinate])])
            case .geometry(let index, let sridIndex):
                guard row.indices.contains(index) else { return Read.invalid }
                var srid: Int?
                if let sridIndex {
                    guard row.indices.contains(sridIndex), let value = numericCoordinate(row[sridIndex]), value == 4326 else {
                        return .unsupportedCRS
                    }
                    srid = 4326
                }
                let value = row[index]
                if case .truncated = value { return .tooLarge }
                if case .bytes(let count, let prefix) = value {
                    guard count == prefix.count else { return .tooLarge }
                    return readWKB(Data(prefix), srid: srid)
                }
                guard let text = value.rawText else { return .invalid }
                return parse(text, srid: srid)
            }
        }
        try Task.checkCancellation()
        var features: [Feature] = []
        var invalid = 0
        var unsupported = 0
        var oversized = 0
        var remaining = IDEDatabaseChartData.markLimit
        for sample in samples {
            switch sample.value {
            case .invalid: invalid += 1
            case .unsupportedCRS: unsupported += 1
            case .tooLarge: oversized += 1
            case .shapes(let shapes):
                let count = shapes.reduce(0) { $0 + $1.coordinates.count }
                guard count <= remaining else { oversized += 1; continue }
                remaining -= count
                for shape in shapes { features.append(Feature(id: features.count, row: sample.row, shape: shape)) }
            }
        }
        return Self(features: features, sampledRows: samples.count, invalidRows: invalid,
                    unsupportedRows: unsupported, omittedForSize: oversized)
    }

    private static func numericCoordinate(_ value: DatabaseValue) -> Double? {
        if case .text(let text) = value { return Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return value.visualizationNumber
    }

    private static func readWKB(_ bytes: Data, srid: Int?) -> Read {
        guard bytes.count <= 131_072 else { return .tooLarge }
        var decoder = IDEDatabaseWKB(bytes: bytes)
        do { return .shapes(try decoder.decode(srid: srid)) }
        catch IDEDatabaseWKB.Failure.unsupportedCRS { return .unsupportedCRS }
        catch IDEDatabaseWKB.Failure.tooLarge { return .tooLarge }
        catch { return .invalid }
    }

    private static func parse(_ input: String, srid: Int?) -> Read {
        guard input.utf8.count <= 262_144 else { return .tooLarge }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("{") {
            guard let value = try? ExtendedJSON.parse(text) else { return .invalid }
            var parser = GeoJSONParser()
            let shapes = parser.shape(value, depth: 0)
            if parser.unsupportedCRS { return .unsupportedCRS }
            if parser.exhausted { return .tooLarge }
            return shapes.flatMap { $0.isEmpty ? nil : Read.shapes($0) } ?? .invalid
        }
        if let bytes = IDEDatabaseWKB.hex(text) { return readWKB(bytes, srid: srid) }
        // SQL geometries must identify WGS84, either in the value or in the selected SRID column.
        guard text.uppercased().hasPrefix("SRID="), let delimiter = text.firstIndex(of: ";") else {
            if text.isEmpty { return .invalid }
            return srid == 4326 ? parseWKT(text) : .unsupportedCRS
        }
        let wkt = text.index(text.startIndex, offsetBy: 5)
        guard delimiter >= wkt, Int(text[wkt..<delimiter]) == 4326 else { return .unsupportedCRS }
        return parseWKT(text[text.index(after: delimiter)...].trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func parseWKT(_ text: String) -> Read {
        guard let open = text.firstIndex(of: "("), text.last == ")" else { return .invalid }
        let type = text[..<open].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let body = text[text.index(after: open)..<text.index(before: text.endIndex)]
        func positions(_ body: Substring) -> [IDEDatabaseMapCoordinate]? {
            let fields = body.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count <= 2_048 else { return nil }
            let points = fields.compactMap { field -> IDEDatabaseMapCoordinate? in
                let units = field.split(whereSeparator: \.isWhitespace)
                guard units.count == 2, let lon = Double(units[0]), let lat = Double(units[1]) else { return nil }
                return IDEDatabaseMapCoordinate(latitude: lat, longitude: lon)
            }
            return points.count == fields.count ? points : nil
        }
        switch type {
        case "POINT", "LINESTRING":
            guard let points = positions(body) else { return .invalid }
            if type == "POINT", points.count == 1 { return .shapes([.points(points)]) }
            return type == "LINESTRING" && points.count >= 2 ? .shapes([.line(points)]) : .invalid
        case "POLYGON":
            var remaining = body.trimmingCharacters(in: .whitespacesAndNewlines)[...]
            var rings: [[IDEDatabaseMapCoordinate]] = []
            while !remaining.isEmpty {
                guard remaining.first == "(", let end = remaining.firstIndex(of: ")"),
                      let ring = positions(remaining[remaining.index(after: remaining.startIndex)..<end]),
                      ring.count >= 4, ring.first == ring.last else { return .invalid }
                rings.append(ring)
                if rings.reduce(0, { $0 + $1.count }) > 2_048 { return .tooLarge }
                remaining = remaining[remaining.index(after: end)...].trimmingCharacters(in: .whitespacesAndNewlines)[...]
                if !remaining.isEmpty {
                    guard remaining.first == "," else { return .invalid }
                    remaining = remaining.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)[...]
                    guard !remaining.isEmpty else { return .invalid }
                }
            }
            return rings.isEmpty ? .invalid : .shapes([.polygon(rings)])
        default: return .invalid
        }
    }

    private struct GeoJSONParser {
        var remaining = 2_048
        var unsupportedCRS = false
        var exhausted = false

        mutating func shape(_ value: BSONValue, depth: Int) -> [Shape]? {
            guard depth <= 16, case .document(let document) = value,
                  case .string(let type)? = document["type"] else { return nil }
            if let crs = document["crs"], crs != .null, !isWGS84(crs) {
                unsupportedCRS = true
                return nil
            }
            switch type {
            case "Feature":
                guard let geometry = document["geometry"] else { return nil }
                return geometry == .null ? [] : shape(geometry, depth: depth + 1)
            case "FeatureCollection", "GeometryCollection":
                let key = type == "FeatureCollection" ? "features" : "geometries"
                guard case .array(let values)? = document[key] else { return nil }
                var result: [Shape] = []
                for item in values {
                    guard let shapes = shape(item, depth: depth + 1) else { return nil }
                    result.append(contentsOf: shapes)
                }
                return result
            default:
                guard let coordinates = document["coordinates"] else { return nil }
                return geometry(type, coordinates)
            }
        }

        private func isWGS84(_ crs: BSONValue) -> Bool {
            guard case .document(let description) = crs,
                  case .document(let properties)? = description["properties"],
                  case .string(let name)? = properties["name"] else { return false }
            return ["EPSG:4326", "URN:OGC:DEF:CRS:EPSG::4326", "URN:OGC:DEF:CRS:OGC:1.3:CRS84",
                    "HTTP://WWW.OPENGIS.NET/DEF/CRS/OGC/1.3/CRS84"].contains(name.uppercased())
        }

        private mutating func geometry(_ type: String, _ value: BSONValue) -> [Shape]? {
            switch type {
            case "Point": return position(value).map { [.points([$0])] }
            case "MultiPoint": return positions(value, minimum: 1).map { [.points($0)] }
            case "LineString": return positions(value, minimum: 2).map { [.line($0)] }
            case "Polygon": return polygon(value).map { [.polygon($0)] }
            case "MultiLineString", "MultiPolygon":
                guard case .array(let parts) = value else { return nil }
                var shapes: [Shape] = []
                for part in parts {
                    if type == "MultiPolygon" {
                        guard let rings = polygon(part) else { return nil }
                        shapes.append(.polygon(rings))
                    } else {
                        guard let points = positions(part, minimum: 2) else { return nil }
                        shapes.append(.line(points))
                    }
                }
                return shapes
            default: return nil
            }
        }

        private mutating func polygon(_ value: BSONValue) -> [[IDEDatabaseMapCoordinate]]? {
            guard case .array(let values) = value, !values.isEmpty else { return nil }
            var rings: [[IDEDatabaseMapCoordinate]] = []
            for item in values {
                guard let ring = positions(item, minimum: 4), ring.first == ring.last else { return nil }
                rings.append(ring)
            }
            return rings
        }

        private mutating func positions(_ value: BSONValue, minimum: Int) -> [IDEDatabaseMapCoordinate]? {
            guard case .array(let items) = value, items.count >= minimum else { return nil }
            var points: [IDEDatabaseMapCoordinate] = []
            for item in items {
                guard let point = position(item) else { return nil }
                points.append(point)
            }
            return points
        }

        private mutating func position(_ value: BSONValue) -> IDEDatabaseMapCoordinate? {
            guard remaining > 0 else { exhausted = true; return nil }
            guard case .array(let coordinates) = value, coordinates.count >= 2,
                  let lon = number(coordinates[0]), let lat = number(coordinates[1]),
                  let coordinate = IDEDatabaseMapCoordinate(latitude: lat, longitude: lon) else { return nil }
            remaining -= 1
            return coordinate
        }

        private func number(_ value: BSONValue) -> Double? {
            switch value {
            case .double(let value): value
            case .int32(let value): Double(value)
            case .int64(let value): Double(value)
            case .decimal128(let value): Double(value.description)
            default: nil
            }
        }
    }
}
