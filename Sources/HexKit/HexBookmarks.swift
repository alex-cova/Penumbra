import Foundation

/// Offsets remembered for one file. At most 256; toggling an existing offset removes it.
public struct HexBookmarks: Sendable, Equatable, Codable {
    public static let limit = 256
    public private(set) var offsets: [Int64]

    public init(offsets: [Int64] = []) {
        self.offsets = Array(offsets.prefix(Self.limit))
    }

    public mutating func toggle(_ offset: Int64) {
        if let index = offsets.firstIndex(of: offset) {
            offsets.remove(at: index)
            return
        }
        if offsets.count >= Self.limit { offsets.removeFirst() }
        offsets.append(offset)
    }
}
