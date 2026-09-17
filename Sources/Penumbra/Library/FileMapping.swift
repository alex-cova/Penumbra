import Darwin
import Foundation

/// Read-only `MAP_PRIVATE` mapping of a **private** inode (APFS clone or copied temp).
///
/// The live user path is never mapped: external truncation of that path cannot SIGBUS this
/// mapping. The temp clone is unlinked after `mmap` so it does not linger on disk; the inode
/// stays alive until ``release()``.
final class FileMapping: @unchecked Sendable {
    private var pointer: UnsafeMutableRawPointer?
    let size: Int
    private let fd: Int32
    private let originalSize: off_t
    private var released = false

    var baseAddress: UnsafeRawPointer? {
        pointer.map { UnsafeRawPointer($0) }
    }

    /// Clones `url` (or copies if `clonefile` is unavailable) and maps the clone.
    static func openPrivateClone(of url: URL) -> FileMapping? {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("penumbra-\(UUID().uuidString).clone")
        guard cloneOrCopy(from: url, to: tempURL) else {
            return nil
        }
        guard let mapping = FileMapping(url: tempURL) else {
            try? FileManager.default.removeItem(at: tempURL)
            return nil
        }
        try? FileManager.default.removeItem(at: tempURL)
        return mapping
    }

    init?(url: URL) {
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                return -1
            }
            return open(path, O_RDONLY | O_CLOEXEC)
        }
        guard fd >= 0 else {
            return nil
        }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_size >= 0 else {
            close(fd)
            return nil
        }
        if status.st_size == 0 {
            self.fd = fd
            self.size = 0
            self.originalSize = 0
            self.pointer = nil
            return
        }
        guard status.st_size <= Int.max else {
            close(fd)
            return nil
        }
        let size = Int(status.st_size)
        let mapped = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0)
        guard mapped != UnsafeMutableRawPointer(bitPattern: -1), let mapped else {
            close(fd)
            return nil
        }
        self.fd = fd
        self.size = size
        self.originalSize = status.st_size
        self.pointer = mapped
        _ = fcntl(fd, F_NOCACHE, 1)
    }

    var hasBeenTruncated: Bool {
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_size >= 0 else {
            return false
        }
        return status.st_size < originalSize
    }

    func bytes() -> UnsafeRawBufferPointer {
        guard let pointer else {
            return UnsafeRawBufferPointer(start: nil, count: 0)
        }
        return UnsafeRawBufferPointer(start: pointer, count: size)
    }

    /// Last `posix_madvise(WILLNEED)` length, for tests that the viewport prefetch is capped.
    private(set) var lastPrefetchByteCount = 0

    func prefetch(byteOffset: Int, count: Int) {
        guard let pointer, size > 0, count > 0 else {
            return
        }
        let start = max(0, byteOffset)
        let end = min(size, start + count)
        guard end > start else {
            return
        }
        lastPrefetchByteCount = end - start
        posix_madvise(pointer + start, end - start, POSIX_MADV_WILLNEED)
    }

    /// Drops mapped pages after the sequential line-metrics scan so RSS is the line index plus
    /// the kept prefix (first viewport), not the entire file. Darwin `MADV_DONTNEED` does not
    /// immediately drop RSS; replacing the mapping with a fresh `mmap` does.
    func discardPages(exceptFirst keepBytes: Int) {
        replaceMapping(keepingFirst: keepBytes)
    }

    /// Unmap the whole file and map it again so previously faulted pages are not resident.
    func replaceMapping(keepingFirst keepBytes: Int) {
        guard size > 0 else {
            return
        }
        if let pointer {
            msync(pointer, size, MS_INVALIDATE)
            munmap(pointer, size)
            self.pointer = nil
        }
        let mapped = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0)
        guard mapped != UnsafeMutableRawPointer(bitPattern: -1), let mapped else {
            return
        }
        pointer = mapped
        prefetch(byteOffset: 0, count: min(max(keepBytes, 0), size))
    }

    /// Remap `[fromByte, upToByte)` so those pages are no longer resident. Offsets are rounded
    /// to page boundaries (start up, end down). The first `fromByte` bytes stay mapped.
    func remapPages(from fromByte: Int, upTo upToByte: Int) {
        guard let pointer, size > 0 else {
            return
        }
        let pageSize = Int(getpagesize())
        guard pageSize > 0 else {
            return
        }
        let start = min(size, ((max(fromByte, 0) + pageSize - 1) / pageSize) * pageSize)
        let end = min(size, max(upToByte, 0) / pageSize * pageSize)
        let length = end - start
        guard length >= pageSize else {
            return
        }
        munmap(pointer + start, length)
        let remapped = mmap(pointer + start, length, PROT_READ, MAP_PRIVATE | MAP_FIXED, fd, off_t(start))
        if remapped == UnsafeMutableRawPointer(bitPattern: -1) || remapped == nil {
            _ = mmap(pointer + start, length, PROT_READ, MAP_PRIVATE | MAP_FIXED, fd, off_t(start))
        }
    }

    func release() {
        guard !released else {
            return
        }
        released = true
        if let pointer, size > 0 {
            munmap(pointer, size)
        }
        close(fd)
    }

    deinit {
        release()
    }

    private static func cloneOrCopy(from source: URL, to destination: URL) -> Bool {
        let cloned = source.withUnsafeFileSystemRepresentation { srcPath -> Bool in
            guard let srcPath else {
                return false
            }
            return destination.withUnsafeFileSystemRepresentation { dstPath -> Bool in
                guard let dstPath else {
                    return false
                }
                return clonefile(srcPath, dstPath, 0) == 0
            }
        }
        if cloned {
            return true
        }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return true
        } catch {
            return false
        }
    }
}
