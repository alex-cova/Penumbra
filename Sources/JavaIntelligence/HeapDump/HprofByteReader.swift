import Darwin
import Foundation

/// Big-endian reads over a byte range of a file, through a private buffer filled with `pread` at
/// absolute positions, so several readers share one descriptor without a shared offset and run in
/// parallel. Nothing maps the file: a dump truncated while open ends a walk with `.truncated`
/// instead of a `SIGBUS`, and resident memory stays one buffer per reader.
final class HprofByteReader {
    let fd: Int32
    /// One past the last byte this reader may read.
    let end: Int64
    private(set) var position: Int64
    private var buffer: UnsafeMutableRawPointer
    private var capacity: Int
    private var bufferStart: Int64 = 0
    private var bufferCount = 0

    init(fd: Int32, start: Int64, end: Int64, capacity: Int = 4 << 20) {
        self.fd = fd
        self.position = start
        self.end = end
        self.capacity = capacity
        self.buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
    }

    deinit { buffer.deallocate() }

    var remaining: Int64 { end - position }
    var isAtEnd: Bool { position >= end }

    /// A pointer to the next `count` bytes, valid until the next call on this reader. Does not advance.
    @inline(__always)
    func peek(_ count: Int) throws -> UnsafeRawPointer {
        let offset = position - bufferStart
        if offset >= 0, offset + Int64(count) <= Int64(bufferCount) {
            return UnsafeRawPointer(buffer + Int(offset))
        }
        try refill(count)
        return UnsafeRawPointer(buffer)
    }

    /// The next `count` bytes, advancing past them.
    @inline(__always)
    func take(_ count: Int) throws -> UnsafeRawPointer {
        let pointer = try peek(count)
        position += Int64(count)
        return pointer
    }

    @inline(__always)
    func skip(_ count: Int64) throws {
        guard count >= 0, position + count <= end else { throw HprofError.truncated(at: min(end, position + max(count, 0))) }
        position += count
    }

    func seek(to offset: Int64) {
        position = offset
    }

    @inline(__always) func u1() throws -> UInt8 { try take(1).load(as: UInt8.self) }
    @inline(__always) func u2() throws -> UInt16 { Self.u2(try take(2), 0) }
    @inline(__always) func u4() throws -> UInt32 { Self.u4(try take(4), 0) }
    @inline(__always) func u8() throws -> UInt64 { Self.u8(try take(8), 0) }

    /// Bytes as `Data`, for the rare variable-length values (names).
    func data(_ count: Int) throws -> Data {
        Data(bytes: try take(count), count: count)
    }

    private func refill(_ count: Int) throws {
        guard position + Int64(count) <= end else { throw HprofError.truncated(at: end) }
        if count > capacity {
            buffer.deallocate()
            capacity = max(count, capacity * 2)
            buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        }
        let wanted = Int(min(Int64(capacity), end - position))
        var filled = 0
        while filled < wanted {
            let result = pread(fd, buffer + filled, wanted - filled, off_t(position) + off_t(filled))
            if result < 0 {
                if errno == EINTR { continue }
                throw HprofError.cannotOpen(String(cString: strerror(errno)))
            }
            if result == 0 { break }
            filled += result
        }
        bufferStart = position
        bufferCount = filled
        guard filled >= count else { throw HprofError.truncated(at: position + Int64(filled)) }
    }

    // MARK: - Big-endian loads at an offset of a peeked pointer

    @inline(__always) static func u2(_ p: UnsafeRawPointer, _ offset: Int) -> UInt16 {
        UInt16(bigEndian: p.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }

    @inline(__always) static func u4(_ p: UnsafeRawPointer, _ offset: Int) -> UInt32 {
        UInt32(bigEndian: p.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    @inline(__always) static func u8(_ p: UnsafeRawPointer, _ offset: Int) -> UInt64 {
        UInt64(bigEndian: p.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }

    @inline(__always) static func id(_ p: UnsafeRawPointer, _ offset: Int, size: Int) -> UInt64 {
        size == 8 ? u8(p, offset) : UInt64(u4(p, offset))
    }
}
