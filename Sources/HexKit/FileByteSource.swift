import Darwin
import Foundation
import os

/// Read-only file bytes through `pread` and a bounded page cache.
///
/// Pages are 64 KB. At most 256 of them stay resident (16 MB). A sequential read
/// pulls one extra page in the scroll direction. A short `pread` zero-fills the
/// missing tail and sets ``isStale``. The file is never mapped.
public final class FileByteSource: @unchecked Sendable, HexByteSource {
    public static let pageSize = 64 * 1024
    public static let maxCachedPages = 256

    private struct Page {
        var bytes: [UInt8]
    }

    private struct State {
        var path: String
        var fd: Int32
        var fileSize: Int64
        var pages: [Int64: Page] = [:]
        var order: [Int64] = []
        var stale = false
        var lastReadStart: Int64 = -1
        var pageLoads = 0
        var allowsReadahead = true
    }

    private let lock = NSLock()
    private var state: State
    private static let openCount = OSAllocatedUnfairLock(initialState: 0)

    /// Descriptors this process still holds for file byte sources.
    public static var openDescriptorCount: Int {
        openCount.withLock { $0 }
    }

    private static func changeOpenCount(_ delta: Int) {
        openCount.withLock { $0 += delta }
    }

    public init(path: String) throws {
        let fd = Darwin.open(path, O_RDONLY)
        guard fd >= 0 else { throw HexByteSourceError.posix(errno) }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let error = errno
            Darwin.close(fd)
            throw HexByteSourceError.posix(error)
        }
        state = State(path: path, fd: fd, fileSize: Int64(info.st_size))
        Self.changeOpenCount(1)
    }

    public convenience init(url: URL) throws {
        try self.init(path: url.path)
    }

    deinit {
        lock.lock()
        let fd = state.fd
        state.fd = -1
        state.pages.removeAll()
        state.order.removeAll()
        lock.unlock()
        if fd >= 0 {
            Darwin.close(fd)
            Self.changeOpenCount(-1)
        }
    }

    public var count: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return state.fileSize
    }

    public var isStale: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state.stale
    }

    public var cachedPageCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return state.pages.count
    }

    public var pageLoadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return state.pageLoads
    }

    public var allowsReadahead: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return state.allowsReadahead
        }
        set {
            lock.lock()
            state.allowsReadahead = newValue
            lock.unlock()
        }
    }

    /// Opens the path again. A save replaces the inode, so the descriptor opened at
    /// load keeps serving the bytes from before that rename.
    public func reopen() throws {
        lock.lock()
        let path = state.path
        lock.unlock()
        let fd = Darwin.open(path, O_RDONLY)
        guard fd >= 0 else { throw HexByteSourceError.posix(errno) }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let error = errno
            Darwin.close(fd)
            throw HexByteSourceError.posix(error)
        }
        lock.lock()
        let old = state.fd
        state.fd = fd
        state.fileSize = Int64(info.st_size)
        state.pages.removeAll()
        state.order.removeAll()
        state.stale = false
        state.lastReadStart = -1
        lock.unlock()
        if old >= 0 {
            Darwin.close(old)
        } else {
            Self.changeOpenCount(1)
        }
    }

    /// Drops cached pages. The descriptor and the last known size stay.
    public func invalidate() {
        lock.lock()
        state.pages.removeAll()
        state.order.removeAll()
        state.stale = false
        lock.unlock()
    }

    /// Re-reads the file size. Cached pages are dropped because their bytes may be wrong.
    public func refreshSize() throws {
        lock.lock()
        defer { lock.unlock() }
        guard state.fd >= 0 else { throw HexByteSourceError.closed }
        var info = stat()
        guard fstat(state.fd, &info) == 0 else { throw HexByteSourceError.posix(errno) }
        state.fileSize = Int64(info.st_size)
        state.pages.removeAll()
        state.order.removeAll()
        state.stale = false
    }

    public func close() {
        lock.lock()
        let fd = state.fd
        state.fd = -1
        state.pages.removeAll()
        state.order.removeAll()
        lock.unlock()
        if fd >= 0 {
            Darwin.close(fd)
            Self.changeOpenCount(-1)
        }
    }

    public func read(_ range: Range<Int64>, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard state.fd >= 0 else { throw HexByteSourceError.closed }
            let available = HexByteRange.clampedCount(range, limit: state.fileSize, capacity: buffer.count)
            guard available > 0, let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            let start = range.lowerBound
            let direction = state.lastReadStart < 0 || start >= state.lastReadStart ? 1 : -1
            state.lastReadStart = start
            if available >= Self.pageSize {
                try Self.readDirect(&state, start: start, count: available, into: base)
                return available
            }
            var copied = 0
            while copied < available {
                let absolute = start + Int64(copied)
                let pageIndex = absolute / Int64(Self.pageSize)
                let page = try Self.page(&state, index: pageIndex)
                let into = Int(absolute - pageIndex * Int64(Self.pageSize))
                let take = min(available - copied, Self.pageSize - into)
                page.bytes.withUnsafeBytes { raw in
                    if let src = raw.baseAddress {
                        memcpy(base.advanced(by: copied), src.advanced(by: into), take)
                    }
                }
                copied += take
            }
            if state.allowsReadahead {
                let edge = start + Int64(available) - 1
                let pageIndex = edge / Int64(Self.pageSize)
                let ahead = pageIndex + Int64(direction)
                if ahead >= 0, ahead * Int64(Self.pageSize) < state.fileSize, state.pages[ahead] == nil {
                    _ = try? Self.page(&state, index: ahead)
                }
            }
        return available
    }

    private static func readDirect(_ state: inout State, start: Int64, count: Int, into base: UnsafeMutablePointer<UInt8>) throws {
        var got = 0
        while got < count {
            let n = pread(state.fd, base.advanced(by: got), count - got, off_t(start + Int64(got)))
            if n > 0 {
                got += n
                continue
            }
            if n == 0 {
                memset(base.advanced(by: got), 0, count - got)
                state.stale = true
                return
            }
            if errno == EINTR { continue }
            throw HexByteSourceError.posix(errno)
        }
    }

    private static func page(_ state: inout State, index: Int64) throws -> Page {
        if let cached = state.pages[index] {
            touch(&state, index)
            return cached
        }
        guard state.fd >= 0 else { throw HexByteSourceError.closed }
        var bytes = [UInt8](repeating: 0, count: pageSize)
        let offset = index * Int64(pageSize)
        let want = Int(min(Int64(pageSize), max(0, state.fileSize - offset)))
        if want > 0 {
            var got = 0
            while got < want {
                let n = bytes.withUnsafeMutableBytes { raw -> Int in
                    guard let pointer = raw.baseAddress else { return -1 }
                    let result = pread(state.fd, pointer.advanced(by: got), want - got, off_t(offset + Int64(got)))
                    return result < 0 ? -1 : result
                }
                if n > 0 {
                    got += n
                    continue
                }
                if n == 0 {
                    state.stale = true
                    break
                }
                if errno == EINTR { continue }
                throw HexByteSourceError.posix(errno)
            }
        }
        state.pageLoads += 1
        let page = Page(bytes: bytes)
        state.pages[index] = page
        state.order.append(index)
        while state.pages.count > maxCachedPages, let oldest = state.order.first {
            state.order.removeFirst()
            if oldest != index {
                state.pages[oldest] = nil
            }
        }
        return page
    }

    private static func touch(_ state: inout State, _ index: Int64) {
        if let existing = state.order.firstIndex(of: index) {
            state.order.remove(at: existing)
        }
        state.order.append(index)
    }
}
