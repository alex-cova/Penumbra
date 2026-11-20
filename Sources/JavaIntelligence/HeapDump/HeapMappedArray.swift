import Darwin
import Foundation

/// A file of fixed-size elements mapped into memory: the storage of every per-object and
/// per-reference array of the heap index. Written while building (disjoint indices from several
/// workers), read-only afterwards. Pages belong to the file, so a 100 M-object index costs page
/// cache the system can evict, not memory the app holds.
final class HeapMappedArray<Element: BitwiseCopyable>: @unchecked Sendable {
    let url: URL
    let count: Int
    let base: UnsafeMutablePointer<Element>
    private let mappedLength: Int
    private let isWritable: Bool

    /// Creates (or truncates) `url` with room for `count` elements, zero-filled.
    static func create(_ url: URL, count: Int) throws -> HeapMappedArray {
        try HeapMappedArray(url: url, count: count, creating: true)
    }

    /// Maps an existing file read-only; its length must hold `count` elements.
    static func open(_ url: URL, count: Int) throws -> HeapMappedArray {
        try HeapMappedArray(url: url, count: count, creating: false)
    }

    private init(url: URL, count: Int, creating: Bool) throws {
        self.url = url
        self.count = count
        self.isWritable = creating
        let bytes = max(count, 1) * MemoryLayout<Element>.stride
        let fd = creating
            ? Darwin.open(url.path, O_RDWR | O_CREAT | O_TRUNC, 0o644)
            : Darwin.open(url.path, O_RDONLY)
        guard fd >= 0 else { throw HeapIndexError.io("open \(url.lastPathComponent)", errno) }
        defer { Darwin.close(fd) }
        if creating {
            guard ftruncate(fd, off_t(bytes)) == 0 else { throw HeapIndexError.io("size \(url.lastPathComponent)", errno) }
        } else {
            var info = stat()
            guard fstat(fd, &info) == 0, Int(info.st_size) >= count * MemoryLayout<Element>.stride else {
                throw HeapIndexError.corrupt("\(url.lastPathComponent) is shorter than its \(count) elements")
            }
        }
        let protection = creating ? (PROT_READ | PROT_WRITE) : PROT_READ
        guard let mapped = mmap(nil, bytes, protection, MAP_SHARED, fd, 0), mapped != MAP_FAILED else {
            throw HeapIndexError.io("map \(url.lastPathComponent)", errno)
        }
        self.mappedLength = bytes
        self.base = mapped.bindMemory(to: Element.self, capacity: max(count, 1))
    }

    deinit {
        munmap(UnsafeMutableRawPointer(base), mappedLength)
    }

    @inline(__always)
    subscript(index: Int) -> Element {
        get { base[index] }
        set { base[index] = newValue }
    }

    var buffer: UnsafeMutableBufferPointer<Element> {
        UnsafeMutableBufferPointer(start: base, count: count)
    }

    /// Tells the system how the pages will be read next.
    func advise(_ advice: Int32) {
        madvise(UnsafeMutableRawPointer(base), mappedLength, advice)
    }

    /// Writes dirty pages to the file (before the index is marked complete).
    func flush() throws {
        guard isWritable else { return }
        guard msync(UnsafeMutableRawPointer(base), mappedLength, MS_SYNC) == 0 else {
            throw HeapIndexError.io("write \(url.lastPathComponent)", errno)
        }
    }
}

public enum HeapIndexError: Error, Equatable, CustomStringConvertible {
    case io(String, Int32)
    case corrupt(String)
    case notEnoughSpace(needed: Int64, available: Int64)
    case tooLarge(String)

    public var description: String {
        switch self {
        case .io(let what, let code): return "Could not \(what): \(String(cString: strerror(code)))."
        case .corrupt(let what): return "The heap index is damaged (\(what)). Delete it and build it again."
        case .notEnoughSpace(let needed, let available):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return "Building the object index needs about \(formatter.string(fromByteCount: needed)) of disk space; \(formatter.string(fromByteCount: available)) is free."
        case .tooLarge(let what): return "This heap dump is too large to index: \(what)."
        }
    }
}
