import Foundation

/// Decodes a byte stream to text without splitting a multi-byte character across two reads.
public struct UTF8ChunkDecoder: Sendable {
    private var pending = Data()

    public init() {}

    public mutating func feed(_ data: Data) -> String {
        pending.append(data)
        guard !pending.isEmpty else { return "" }
        // Hold back a trailing incomplete sequence (at most 3 bytes) for the next read.
        var keep = 0
        for back in 1...min(3, pending.count) {
            let byte = pending[pending.count - back]
            if byte & 0b1100_0000 == 0b1000_0000 { continue }  // continuation byte: look further back
            let needed = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
            if needed > back { keep = back }
            break
        }
        let ready = pending.prefix(pending.count - keep)
        pending = Data(pending.suffix(keep))
        return String(decoding: ready, as: UTF8.self)
    }

    /// Whatever is still held back, once the stream has ended.
    public mutating func finish() -> String {
        defer { pending = Data() }
        return String(decoding: pending, as: UTF8.self)
    }
}
