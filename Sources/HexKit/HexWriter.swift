import Darwin
import Foundation

/// Size and modification time of a file, captured with `stat`.
public struct HexFileIdentity: Sendable, Equatable {
    public var size: Int64
    public var modifiedSeconds: Int64
    public var modifiedNanoseconds: Int64
    public var mode: UInt32

    public init(size: Int64, modifiedSeconds: Int64, modifiedNanoseconds: Int64, mode: UInt32) {
        self.size = size
        self.modifiedSeconds = modifiedSeconds
        self.modifiedNanoseconds = modifiedNanoseconds
        self.mode = mode
    }

    public static func capture(url: URL) throws -> HexFileIdentity {
        var info = stat()
        guard stat(url.path, &info) == 0 else { throw HexWriteError.posix(errno) }
        return HexFileIdentity(
            size: Int64(info.st_size),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            mode: UInt32(info.st_mode)
        )
    }

    public func matchesContent(of other: HexFileIdentity) -> Bool {
        size == other.size && modifiedSeconds == other.modifiedSeconds && modifiedNanoseconds == other.modifiedNanoseconds
    }
}

public enum HexWriteError: Error, Equatable, Sendable {
    case changedOnDisk
    case cancelled
    case noDestination
    case posix(Int32)
    case shortWrite
}

public final class HexWriteCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    public init() {}

    public func cancel() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}

/// Streams a document to a temporary file in the destination directory, then renames it over the target.
public enum HexWriter {
    public static func save(
        _ document: HexDocument,
        to destination: URL,
        expected: HexFileIdentity?,
        overwriteChanged: Bool = false,
        cancellation: HexWriteCancellation? = nil,
        progress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) throws {
        if let expected, !overwriteChanged {
            guard FileManager.default.fileExists(atPath: destination.path) else { throw HexWriteError.changedOnDisk }
            let current = try HexFileIdentity.capture(url: destination)
            guard current.matchesContent(of: expected) else { throw HexWriteError.changedOnDisk }
        }
        if cancellation?.isCancelled == true { throw HexWriteError.cancelled }

        let directory = destination.deletingLastPathComponent()
        let temp = directory.appendingPathComponent(".\(destination.lastPathComponent).hex-\(UUID().uuidString)")
        let fd = Darwin.open(temp.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        guard fd >= 0 else { throw HexWriteError.posix(errno) }
        defer { Darwin.close(fd) }

        do {
            let mode = try fileMode(destination: destination, expected: expected)
            var buffer = [UInt8](repeating: 0, count: 1 << 20)
            var offset: Int64 = 0
            let total = document.count
            while offset < total {
                if cancellation?.isCancelled == true { throw HexWriteError.cancelled }
                let want = Int(min(Int64(buffer.count), total - offset))
                let got = buffer.withUnsafeMutableBytes { raw in
                    document.read(offset..<(offset + Int64(want)), into: raw)
                }
                guard got == want else { throw HexWriteError.shortWrite }
                try writeAll(fd, buffer, got)
                offset += Int64(got)
                progress?(offset, total)
            }
            if fchmod(fd, mode_t(mode & 0o7777)) != 0 { throw HexWriteError.posix(errno) }
            if fsync(fd) != 0 { throw HexWriteError.posix(errno) }
            if cancellation?.isCancelled == true { throw HexWriteError.cancelled }
            if Darwin.rename(temp.path, destination.path) != 0 { throw HexWriteError.posix(errno) }
            progress?(total, total)
        } catch {
            Darwin.unlink(temp.path)
            throw error
        }
    }

    private static func fileMode(destination: URL, expected: HexFileIdentity?) throws -> UInt32 {
        if let expected { return expected.mode }
        var info = stat()
        if stat(destination.path, &info) == 0 { return UInt32(info.st_mode) }
        return 0o644
    }

    private static func writeAll(_ fd: Int32, _ buffer: [UInt8], _ count: Int) throws {
        var written = 0
        while written < count {
            let n = buffer.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                let result = Darwin.write(fd, base.advanced(by: written), count - written)
                return result < 0 ? -1 : result
            }
            if n > 0 {
                written += n
                continue
            }
            if errno == EINTR { continue }
            throw HexWriteError.posix(errno)
        }
    }
}
