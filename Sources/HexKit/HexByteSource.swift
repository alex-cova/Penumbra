import Foundation

/// A random-access source of bytes. Reads never look at more than `range`.
///
/// `count` is the logical length. A read that starts at or past `count` returns 0.
/// A read that runs past `count` copies only the bytes that exist.
public protocol HexByteSource: Sendable {
    var count: Int64 { get }
    /// Copies bytes from `range` into `buffer`. Returns how many bytes were copied.
    func read(_ range: Range<Int64>, into buffer: UnsafeMutableRawBufferPointer) throws -> Int
}

public enum HexByteSourceError: Error, Equatable, Sendable {
    case closed
    case posix(Int32)
    case outOfRange
}

/// In-memory bytes. Safe to share across tasks.
public final class MemoryByteSource: @unchecked Sendable, HexByteSource {
    private let lock = NSLock()
    private var bytes: ContiguousArray<UInt8>

    public init(_ bytes: [UInt8]) {
        self.bytes = ContiguousArray(bytes)
    }

    public var count: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return Int64(bytes.count)
    }

    public func read(_ range: Range<Int64>, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        let available = HexByteRange.clampedCount(range, limit: Int64(bytes.count), capacity: buffer.count)
        guard available > 0, let base = buffer.baseAddress else { return 0 }
        let start = Int(range.lowerBound)
        bytes.withUnsafeBytes { raw in
            guard let src = raw.baseAddress else { return }
            memcpy(base, src.advanced(by: start), available)
        }
        return available
    }
}

/// A logical span of one repeated byte. `count` does not allocate.
public struct UniformByteSource: HexByteSource, Sendable {
    public let count: Int64
    public let byte: UInt8

    public init(count: Int64, byte: UInt8 = 0) {
        self.count = max(0, count)
        self.byte = byte
    }

    public func read(_ range: Range<Int64>, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let available = HexByteRange.clampedCount(range, limit: count, capacity: buffer.count)
        guard available > 0, let base = buffer.baseAddress else { return 0 }
        memset(base, Int32(byte), available)
        return available
    }
}

/// Records every range a caller asks for, then forwards the read.
public final class RecordingByteSource: @unchecked Sendable, HexByteSource {
    public let inner: any HexByteSource
    private let lock = NSLock()
    public private(set) var ranges: [Range<Int64>] = []
    public private(set) var bytesRequested: Int64 = 0
    public private(set) var maxEnd: Int64 = 0

    public init(_ inner: any HexByteSource) {
        self.inner = inner
    }

    public var count: Int64 { inner.count }

    public func read(_ range: Range<Int64>, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        lock.lock()
        ranges.append(range)
        if range.upperBound > range.lowerBound {
            bytesRequested += range.upperBound - range.lowerBound
            maxEnd = max(maxEnd, range.upperBound)
        }
        lock.unlock()
        return try inner.read(range, into: buffer)
    }

    public func reset() {
        lock.lock()
        ranges.removeAll()
        bytesRequested = 0
        maxEnd = 0
        lock.unlock()
    }
}

enum HexByteRange {
    static func clampedCount(_ range: Range<Int64>, limit: Int64, capacity: Int) -> Int {
        guard capacity > 0, range.lowerBound >= 0, range.lowerBound < limit, range.upperBound > range.lowerBound else {
            return 0
        }
        let end = min(range.upperBound, limit)
        let span = end - range.lowerBound
        return Int(min(span, Int64(capacity)))
    }
}
