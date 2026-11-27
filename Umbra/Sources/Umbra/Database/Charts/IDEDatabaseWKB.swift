import Foundation

struct IDEDatabaseWKB {
    enum Failure: Error { case invalid, unsupportedCRS, tooLarge }

    private let bytes: Data
    private var offset = 0
    private var vertices = 2_048

    init(bytes: Data) {
        self.bytes = bytes
    }

    static func hex(_ text: String) -> Data? {
        let stripped = text.hasPrefix("\\x") || text.hasPrefix("0x") ? text.dropFirst(2) : text[...]
        let digits = Array(stripped.utf8)
        guard digits.count >= 10, digits.count.isMultiple(of: 2) else { return nil }
        func digit(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: byte - 48
            case 65...70: byte - 55
            case 97...102: byte - 87
            default: nil
            }
        }
        var bytes = Data(capacity: digits.count / 2)
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let high = digit(digits[index]), let low = digit(digits[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
        }
        return bytes
    }

    mutating func decode(srid: Int?) throws -> [IDEDatabaseMapData.Shape] {
        let result = try shape(srid: srid, expected: nil, depth: 0)
        guard offset == bytes.count, !result.isEmpty else { throw Failure.invalid }
        return result
    }

    private mutating func shape(srid: Int?, expected: UInt64?, depth: Int) throws -> [IDEDatabaseMapData.Shape] {
        guard depth <= 16 else { throw Failure.tooLarge }
        let order = try read(width: 1, little: true)
        guard order <= 1 else { throw Failure.invalid }
        let little = order == 1
        let type = try read(width: 4, little: little)
        let code = type & 0x1fff_ffff
        let kind = code % 1_000
        let isoDimensions = code / 1_000
        guard isoDimensions <= 3, expected == nil || expected == kind else { throw Failure.invalid }
        let dimensions = 2 + ((type & 0x8000_0000 != 0 || isoDimensions == 1 || isoDimensions == 3) ? 1 : 0)
            + ((type & 0x4000_0000 != 0 || isoDimensions == 2 || isoDimensions == 3) ? 1 : 0)
        let actualSRID = type & 0x2000_0000 != 0 ? Int(try read(width: 4, little: little)) : srid
        guard actualSRID == 4326 else { throw Failure.unsupportedCRS }
        switch kind {
        case 1:
            return [.points([try coordinate(little: little, dimensions: dimensions)])]
        case 2:
            return [.line(try positions(little: little, dimensions: dimensions, minimum: 2))]
        case 3:
            let count = try count(little: little)
            guard count > 0 else { throw Failure.invalid }
            var rings: [[IDEDatabaseMapCoordinate]] = []
            for _ in 0..<count {
                let ring = try positions(little: little, dimensions: dimensions, minimum: 4)
                guard ring.first == ring.last else { throw Failure.invalid }
                rings.append(ring)
            }
            return [.polygon(rings)]
        case 4...7:
            let count = try count(little: little)
            var shapes: [IDEDatabaseMapData.Shape] = []
            for _ in 0..<count {
                shapes += try shape(srid: actualSRID, expected: kind == 7 ? nil : kind - 3, depth: depth + 1)
            }
            return shapes
        default: throw Failure.invalid
        }
    }

    private mutating func positions(little: Bool, dimensions: Int, minimum: Int) throws -> [IDEDatabaseMapCoordinate] {
        let count = try count(little: little)
        guard count >= minimum else { throw Failure.invalid }
        return try (0..<count).map { _ in try coordinate(little: little, dimensions: dimensions) }
    }

    private mutating func coordinate(little: Bool, dimensions: Int) throws -> IDEDatabaseMapCoordinate {
        guard vertices > 0 else { throw Failure.tooLarge }
        let lon = Double(bitPattern: try read(width: 8, little: little))
        let lat = Double(bitPattern: try read(width: 8, little: little))
        for _ in 2..<dimensions { _ = try read(width: 8, little: little) }
        guard let point = IDEDatabaseMapCoordinate(latitude: lat, longitude: lon) else { throw Failure.invalid }
        vertices -= 1
        return point
    }

    private mutating func count(little: Bool) throws -> Int {
        let count = Int(try read(width: 4, little: little))
        guard count <= vertices else { throw Failure.tooLarge }
        return count
    }

    private mutating func read(width: Int, little: Bool) throws -> UInt64 {
        guard offset + width <= bytes.count else { throw Failure.invalid }
        defer { offset += width }
        return (0..<width).reduce(0) { value, index in
            let shift = (little ? index : width - index - 1) * 8
            return value | (UInt64(bytes[bytes.startIndex + offset + index]) << shift)
        }
    }
}
