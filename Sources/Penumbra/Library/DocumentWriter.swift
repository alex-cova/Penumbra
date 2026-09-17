import Darwin
import Foundation

/// Errors thrown by ``DocumentWriter`` and the public save APIs built on it.
public enum DocumentWriteError: Error, Equatable {
    /// The write task was cancelled before `rename`.
    case cancelled
    /// Only UTF-8 is supported.
    case unsupportedEncoding
    /// Save-as was required and no destination URL was provided.
    case noDestination
    /// A file-backed document had no live buffer to write.
    case bufferUnavailable
    /// A POSIX I/O step failed. The destination is unchanged if `rename` did not run.
    case ioFailure
}

public struct DocumentWriteOptions: Sendable, Equatable {
    public var encoding: String.Encoding = .utf8
    /// Reserved; v1 always writes atomically.
    public var atomic: Bool = true

    public init(encoding: String.Encoding = .utf8, atomic: Bool = true) {
        self.encoding = encoding
        self.atomic = atomic
    }
}

public struct DocumentWriteResult: Sendable, Equatable {
    public var wroteBytes: Int64
    /// `true` iff the live buffer was still the snapshot we wrote (same `StringView` instance
    /// and unchanged `contentGeneration`). Hosts **must** read this (or `WorkbenchDocument.isDirty`)
    /// — a throwing-void success does not mean the buffer is on disk.
    public var generationMatched: Bool
    public var compacted: Bool

    public init(wroteBytes: Int64, generationMatched: Bool, compacted: Bool) {
        self.wroteBytes = wroteBytes
        self.generationMatched = generationMatched
        self.compacted = compacted
    }
}

struct DocumentWriteFooter: Sendable {
    var utf8Length: Int
    var utf16Length: Int
    /// Concatenated-byte count; CRLF = 1. Not the sum of per-piece `lineFeedCount`.
    var lineFeedCount: Int
    var checkpoints: [UTF8DocumentScanner.Checkpoint]
}

enum DocumentWriteSource: Sendable {
    case contiguous(String)
    case pieceTree(PieceTreeContentSnapshot)
}

/// Streams UTF-8 to a temp file in the destination directory, then `fsync` + `rename`.
enum DocumentWriter {
    /// Test-only. When non-nil, `write` throws `.ioFailure` after this many bytes and unlinks the temp.
    nonisolated(unsafe) static var debugFailAfterBytes: Int?

    private static let writeChunkSize = 64 * 1024

    static func write(
        _ source: DocumentWriteSource,
        to url: URL,
        options: DocumentWriteOptions = .init(),
        progress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) throws -> DocumentWriteFooter {
        try PenumbraSignposts.interval("DocumentWriter.write") {
            try writeUTF8(source, to: url, options: options, progress: progress)
        }
    }

    private static func writeUTF8(
        _ source: DocumentWriteSource,
        to url: URL,
        options: DocumentWriteOptions,
        progress: (@Sendable (Int64, Int64) -> Void)?
    ) throws -> DocumentWriteFooter {
        guard options.encoding == .utf8 else {
            throw DocumentWriteError.unsupportedEncoding
        }
        try checkInterrupted(written: 0)

        let directory = url.deletingLastPathComponent()
        let created = try createTemp(inDirectory: directory, destName: url.lastPathComponent)
        var fd = created.fd
        let tempPath = created.path
        var committed = false
        defer {
            if fd >= 0 {
                close(fd)
                fd = -1
            }
            if !committed {
                unlink(tempPath)
            }
        }

        var written: Int64 = 0
        var footer = FooterAccumulator()
        switch source {
        case .contiguous(var string):
            try string.withUTF8 { buffer in
                let total = Int64(buffer.count)
                progress?(0, total)
                try streamBytes(
                    UnsafeRawBufferPointer(buffer),
                    fd: fd,
                    written: &written,
                    total: total,
                    footer: &footer,
                    progress: progress
                )
            }
        case .pieceTree(let snapshot):
            let total = Int64(snapshot.utf8Length)
            progress?(0, total)
            for piece in snapshot.pieces {
                try checkInterrupted(written: written)
                try snapshot.withUTF8(of: piece) { bytes in
                    try streamBytes(
                        bytes,
                        fd: fd,
                        written: &written,
                        total: total,
                        footer: &footer,
                        progress: progress
                    )
                }
            }
        }

        try applyMetadata(to: fd, tempPath: tempPath, destination: url)
        if fsync(fd) != 0 {
            throw DocumentWriteError.ioFailure
        }
        if close(fd) != 0 {
            fd = -1
            throw DocumentWriteError.ioFailure
        }
        fd = -1

        try checkInterrupted(written: written)

        let renamed = url.withUnsafeFileSystemRepresentation { dest -> Bool in
            guard let dest else {
                return false
            }
            return tempPath.withCString { src in
                rename(src, dest) == 0
            }
        }
        guard renamed else {
            throw DocumentWriteError.ioFailure
        }
        committed = true
        fsyncDirectory(directory)

        if written == 0 {
            progress?(0, 0)
        }
        return footer.finish()
    }

    private static func streamBytes(
        _ bytes: UnsafeRawBufferPointer,
        fd: Int32,
        written: inout Int64,
        total: Int64,
        footer: inout FooterAccumulator,
        progress: (@Sendable (Int64, Int64) -> Void)?
    ) throws {
        var offset = 0
        while offset < bytes.count {
            try checkInterrupted(written: written)
            var chunk = min(writeChunkSize, bytes.count - offset)
            if let limit = debugFailAfterBytes {
                let allowed = Int64(limit) - written
                if allowed <= 0 {
                    throw DocumentWriteError.ioFailure
                }
                chunk = min(chunk, Int(allowed))
            }
            let end = offset + chunk
            let slice = UnsafeRawBufferPointer(rebasing: bytes[offset..<end])
            try writeAll(fd: fd, bytes: slice)
            footer.consume(slice)
            written += Int64(chunk)
            offset = end
            progress?(written, total)
            if let limit = debugFailAfterBytes, written >= Int64(limit) {
                throw DocumentWriteError.ioFailure
            }
        }
    }

    private static func writeAll(fd: Int32, bytes: UnsafeRawBufferPointer) throws {
        guard let base = bytes.baseAddress else {
            if bytes.count == 0 {
                return
            }
            throw DocumentWriteError.ioFailure
        }
        var offset = 0
        while offset < bytes.count {
            if Task.isCancelled {
                throw DocumentWriteError.cancelled
            }
            let n = Darwin.write(fd, base + offset, bytes.count - offset)
            if n < 0 {
                if errno == EINTR {
                    continue
                }
                throw DocumentWriteError.ioFailure
            }
            if n == 0 {
                throw DocumentWriteError.ioFailure
            }
            offset += n
        }
    }

    private static func checkInterrupted(written: Int64) throws {
        if Task.isCancelled {
            throw DocumentWriteError.cancelled
        }
        if let limit = debugFailAfterBytes, written >= Int64(limit) {
            throw DocumentWriteError.ioFailure
        }
    }

    private static func createTemp(inDirectory directory: URL, destName: String) throws -> (path: String, fd: Int32) {
        for _ in 0..<8 {
            let name = ".\(destName).penumbra-\(UUID().uuidString).tmp"
            let url = directory.appendingPathComponent(name)
            let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else {
                    return -1
                }
                return open(path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
            }
            if fd >= 0 {
                guard let path = url.withUnsafeFileSystemRepresentation({ $0.map(String.init(cString:)) }) else {
                    close(fd)
                    throw DocumentWriteError.ioFailure
                }
                return (path, fd)
            }
            if errno != EEXIST {
                throw DocumentWriteError.ioFailure
            }
        }
        throw DocumentWriteError.ioFailure
    }

    private static func applyMetadata(to fd: Int32, tempPath: String, destination url: URL) throws {
        var status = stat()
        let existed = url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else {
                return false
            }
            return lstat(path, &status) == 0
        }
        if existed {
            if fchmod(fd, status.st_mode & ~S_IFMT) != 0 {
                throw DocumentWriteError.ioFailure
            }
            _ = fchown(fd, status.st_uid, status.st_gid)
            try url.withUnsafeFileSystemRepresentation { destPath in
                guard let destPath else {
                    throw DocumentWriteError.ioFailure
                }
                try tempPath.withCString { tempC in
                    copyXattrs(from: destPath, to: tempC)
                    try copyACL(from: destPath, to: tempC)
                }
            }
        } else {
            let mode = try umaskAdjustedNewFileMode(inDirectory: url.deletingLastPathComponent())
            if fchmod(fd, mode) != 0 {
                throw DocumentWriteError.ioFailure
            }
        }
    }

    /// `open(O_CREAT, 0o666)` applies umask without mutating the process-global mask.
    private static func umaskAdjustedNewFileMode(inDirectory directory: URL) throws -> mode_t {
        let probeURL = directory.appendingPathComponent(".penumbra-umask-\(UUID().uuidString).tmp")
        let fd = probeURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                return -1
            }
            return open(path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o666)
        }
        guard fd >= 0 else {
            throw DocumentWriteError.ioFailure
        }
        defer {
            close(fd)
            probeURL.withUnsafeFileSystemRepresentation { path in
                if let path {
                    unlink(path)
                }
            }
        }
        var status = stat()
        guard fstat(fd, &status) == 0 else {
            throw DocumentWriteError.ioFailure
        }
        return status.st_mode & ~S_IFMT
    }

    /// Resource forks (`com.apple.ResourceFork`) and `st_birthtime` are not preserved.
    private static func copyXattrs(from source: UnsafePointer<CChar>, to destination: UnsafePointer<CChar>) {
        let listed = listxattr(source, nil, 0, 0)
        guard listed > 0 else {
            return
        }
        var names = [CChar](repeating: 0, count: listed)
        guard listxattr(source, &names, names.count, 0) > 0 else {
            return
        }
        names.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else {
                return
            }
            var offset = 0
            while offset < buffer.count {
                let name = String(cString: base + offset)
                offset += name.utf8.count + 1
                if name.isEmpty || name == "com.apple.ResourceFork" {
                    continue
                }
                let valueSize = getxattr(source, name, nil, 0, 0, 0)
                guard valueSize >= 0 else {
                    continue
                }
                if valueSize == 0 {
                    _ = setxattr(destination, name, UnsafeRawPointer(bitPattern: 1), 0, 0, 0)
                    continue
                }
                var value = [UInt8](repeating: 0, count: valueSize)
                guard getxattr(source, name, &value, value.count, 0, 0) >= 0 else {
                    continue
                }
                _ = setxattr(destination, name, value, value.count, 0, 0)
            }
        }
    }

    private static func copyACL(from source: UnsafePointer<CChar>, to destination: UnsafePointer<CChar>) throws {
        guard let acl = acl_get_file(source, ACL_TYPE_EXTENDED) else {
            return
        }
        defer {
            acl_free(UnsafeMutableRawPointer(acl))
        }
        if acl_set_file(destination, ACL_TYPE_EXTENDED, acl) != 0 {
            throw DocumentWriteError.ioFailure
        }
    }

    private static func fsyncDirectory(_ directory: URL) {
        let dirFd = directory.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                return -1
            }
            return open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard dirFd >= 0 else {
            return
        }
        _ = fsync(dirFd)
        close(dirFd)
    }
}

/// Incremental copy of ``UTF8DocumentScanner/scan`` so CRLF / UTF-8 splits across pieces stay correct.
private struct FooterAccumulator {
    private var utf8Length = 0
    private var utf16Length = 0
    private var lineFeedCount = 0
    private var checkpoints: [UTF8DocumentScanner.Checkpoint] = [
        UTF8DocumentScanner.Checkpoint(utf8Offset: 0, utf16Offset: 0, lineCount: 0)
    ]
    private var pending: [UInt8] = []

    mutating func consume(_ bytes: UnsafeRawBufferPointer) {
        walk(bytes, eof: false)
    }

    mutating func finish() -> DocumentWriteFooter {
        if !pending.isEmpty {
            let leftover = pending
            pending.removeAll(keepingCapacity: true)
            leftover.withUnsafeBytes { walk($0, eof: true) }
        }
        return DocumentWriteFooter(
            utf8Length: utf8Length,
            utf16Length: utf16Length,
            lineFeedCount: lineFeedCount,
            checkpoints: checkpoints
        )
    }

    private mutating func walk(_ bytes: UnsafeRawBufferPointer, eof: Bool) {
        var offset = 0
        func available() -> Int {
            pending.count + (bytes.count - offset)
        }
        func peek(_ ahead: Int) -> UInt8? {
            if ahead < pending.count {
                return pending[ahead]
            }
            let index = offset + (ahead - pending.count)
            guard index < bytes.count else {
                return nil
            }
            return bytes[index]
        }
        func consumeBytes(_ count: Int) {
            var remaining = count
            if remaining > 0, !pending.isEmpty {
                let fromPending = min(remaining, pending.count)
                pending.removeFirst(fromPending)
                remaining -= fromPending
            }
            offset += remaining
            utf8Length += count
        }

        while available() > 0 {
            if utf8Length - checkpoints[checkpoints.count - 1].utf8Offset >= UTF8DocumentScanner.checkpointStride {
                checkpoints.append(
                    UTF8DocumentScanner.Checkpoint(
                        utf8Offset: utf8Length,
                        utf16Offset: utf16Length,
                        lineCount: lineFeedCount
                    )
                )
            }
            guard let lead = peek(0) else {
                break
            }
            if let token = Self.token(lead: lead, available: available(), peek: peek, eof: eof) {
                utf16Length += token.utf16
                lineFeedCount += token.feeds
                consumeBytes(token.advance)
            } else {
                break
            }
        }

        if offset < bytes.count || !pending.isEmpty {
            var leftover = pending
            leftover.reserveCapacity(pending.count + (bytes.count - offset))
            if offset < bytes.count {
                leftover.append(contentsOf: bytes[offset..<bytes.count])
            }
            pending = leftover
        } else {
            pending.removeAll(keepingCapacity: true)
        }
    }

    private static func token(
        lead: UInt8,
        available: Int,
        peek: (Int) -> UInt8?,
        eof: Bool
    ) -> (advance: Int, utf16: Int, feeds: Int)? {
        if lead == 0x0A {
            return (1, 1, 1)
        }
        if lead == 0x0D {
            if available < 2 {
                return eof ? (1, 1, 1) : nil
            }
            if peek(1) == 0x0A {
                return (2, 2, 1)
            }
            return (1, 1, 1)
        }
        if lead == 0xC2 {
            if available < 2 {
                return eof ? (1, 1, 0) : nil
            }
            if peek(1) == 0x85 {
                return (2, 1, 1)
            }
            return (2, 1, 0)
        }
        if lead == 0xE2 {
            if available < 3 {
                return eof ? (min(3, available), 1, 0) : nil
            }
            if peek(1) == 0x80, let third = peek(2), third == 0xA8 || third == 0xA9 {
                return (3, 1, 1)
            }
            return (3, 1, 0)
        }
        let needed: Int
        let units: Int
        if lead < 0x80 {
            needed = 0
            units = 1
        } else if lead < 0xC0 {
            needed = 0
            units = 1
        } else if lead < 0xE0 {
            needed = 1
            units = 1
        } else if lead < 0xF0 {
            needed = 2
            units = 1
        } else if lead < 0xF8 {
            needed = 3
            units = 2
        } else {
            needed = 0
            units = 1
        }
        let size = 1 + needed
        if available < size {
            return eof ? (available, units, 0) : nil
        }
        return (size, units, 0)
    }
}

/// FIFO lock held for the whole `snapshot → write → compact` interval of ``TextView/write``.
final class DocumentWriteLock: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let mutex = NSLock()
    private var isLocked = false
    private var waiters: [Waiter] = []

    func acquire() async throws {
        let id = UUID()
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    mutex.lock()
                    if Task.isCancelled {
                        mutex.unlock()
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    if !isLocked {
                        isLocked = true
                        mutex.unlock()
                        continuation.resume()
                        return
                    }
                    waiters.append(Waiter(id: id, continuation: continuation))
                    if Task.isCancelled {
                        if let index = waiters.firstIndex(where: { $0.id == id }) {
                            waiters.remove(at: index)
                            mutex.unlock()
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                    }
                    mutex.unlock()
                }
            } onCancel: { [id] in
                self.cancelWaiter(id: id)
            }
        } catch is CancellationError {
            throw DocumentWriteError.cancelled
        }
    }

    func release() {
        mutex.lock()
        if waiters.isEmpty {
            isLocked = false
            mutex.unlock()
        } else {
            let next = waiters.removeFirst()
            mutex.unlock()
            next.continuation.resume()
        }
    }

    private func cancelWaiter(id: UUID) {
        mutex.lock()
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            mutex.unlock()
            waiter.continuation.resume(throwing: CancellationError())
        } else {
            mutex.unlock()
        }
    }
}

extension DocumentWriter {
    /// Off-main write that inherits cancellation from the calling task.
    static func writeCooperatively(
        _ source: DocumentWriteSource,
        to url: URL,
        options: DocumentWriteOptions = .init(),
        progress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> DocumentWriteFooter {
        let writer = Task.detached(priority: .userInitiated) {
            try DocumentWriter.write(source, to: url, options: options, progress: progress)
        }
        do {
            return try await withTaskCancellationHandler {
                try await writer.value
            } onCancel: {
                writer.cancel()
            }
        } catch is CancellationError {
            throw DocumentWriteError.cancelled
        }
    }
}
