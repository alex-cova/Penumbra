import Darwin
import Foundation

/// `.java` files under a source root, with the same relative paths ``SourceRoot/javaFileURLs()``
/// produces and stamps comparable to ``JavaStamp/init(url:)``.
///
/// One `getattrlistbulk` call per directory replaces a `URL` plus `resourceValues` per file, which
/// is what a no-change `refs.idx` open was spending its time on. Returns `nil` when the volume
/// rejects the bulk call (or the walk is cancelled); the caller then uses the URL enumerator.
enum JavaSourceStampScan {
    /// `vnode.h`: `VREG` is 1, `VDIR` is 2, `VLNK` is 5. Directory links are not descended into,
    /// matching `FileManager`'s enumerator. A link whose name ends in `.java` is indexed.
    private static let regularFile: UInt32 = 1
    private static let directory: UInt32 = 2
    private static let symbolicLink: UInt32 = 5
    /// `sys/attr.h`. The importer types these macros as `Int32`, which does not fit the unsigned
    /// `0x80000000` bit, so the values are written out here.
    private static let returnedAttrs: UInt32 = 0x8000_0000
    private static let nameAttr: UInt32 = 0x0000_0001
    private static let objTypeAttr: UInt32 = 0x0000_0008
    private static let modTimeAttr: UInt32 = 0x0000_0400
    private static let dataLengthAttr: UInt32 = 0x0000_0200
    /// `FSOPT_NOFOLLOW`.
    private static let noFollow: UInt64 = 1

    static func javaFiles(in directory: URL) -> [(relativePath: String, stamp: JavaStamp)]? {
        let root = realPath(directory.path)
        let rootFD = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootFD >= 0 else { return nil }
        var stack: [(fd: Int32, relative: String)] = [(rootFD, "")]
        var results: [(relativePath: String, stamp: JavaStamp)] = []
        let bufferSize = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer {
            buffer.deallocate()
            while let item = stack.popLast() { close(item.fd) }
        }

        var list = attrlist()
        list.bitmapcount = 5
        list.commonattr = returnedAttrs | nameAttr | objTypeAttr | modTimeAttr
        list.fileattr = dataLengthAttr

        while let current = stack.popLast() {
            defer { close(current.fd) }
            if Task.isCancelled { return nil }
            var done = false
            while !done {
                var count = Int32(0)
                repeat {
                    count = getattrlistbulk(current.fd, &list, buffer, bufferSize, noFollow)
                } while count < 0 && errno == EINTR
                if count < 0 { return nil }
                if count == 0 { done = true; continue }
                var cursor = 0
                for _ in 0..<count {
                    guard cursor + 4 <= bufferSize else { return nil }
                    let record = buffer.advanced(by: cursor)
                    let length = Int(record.load(as: UInt32.self))
                    guard length >= 4, cursor + length <= bufferSize else { return nil }
                    guard let entry = parse(record, length: length) else { return nil }
                    cursor += length
                    if entry.name.isEmpty || entry.name.hasPrefix(".") { continue }
                    if entry.type == Self.directory {
                        if SourceRoot.ignoredDirectoryNames.contains(entry.name) { continue }
                        let child = entry.name.withCString { openat(current.fd, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
                        guard child >= 0 else { continue }
                        let relative = current.relative.isEmpty ? entry.name : current.relative + "/" + entry.name
                        stack.append((child, relative))
                        continue
                    }
                    let relative = current.relative.isEmpty ? entry.name : current.relative + "/" + entry.name
                    if entry.type == Self.symbolicLink, entry.name.hasSuffix(".java") {
                        // `FSOPT_NOFOLLOW` reports the link itself. `JavaStamp(url:)` stats the
                        // target, which is what the URL walk records.
                        let target = URL(fileURLWithPath: root + "/" + relative)
                        if let stamp = JavaStamp(url: target) {
                            results.append((relative, stamp))
                        }
                        continue
                    }
                    guard entry.type == Self.regularFile, entry.name.hasSuffix(".java") else { continue }
                    // A `.java` file with no size or mtime would look deleted. Fail the scan instead
                    // so the caller uses the URL walk and keeps every file.
                    guard let size = entry.size, let modified = entry.modified else { return nil }
                    results.append((relative, JavaStamp(size: size, modificationDate: modified)))
                }
            }
        }
        return results
    }

    private struct Entry {
        var name: String
        var type: UInt32
        var size: Int64?
        var modified: Double?
    }

    /// Walks one bulk record. `ATTR_CMN_RETURNED_ATTRS` is first; the rest follow bit order, packed
    /// on 4-byte boundaries (a `timespec` is not moved to an 8-byte boundary). The name bytes sit
    /// at the `attrreference` offset and are not in line with the fixed fields.
    private static func parse(_ record: UnsafeMutableRawPointer, length: Int) -> Entry? {
        var offset = 4
        guard offset + MemoryLayout<attribute_set_t>.size <= length else { return nil }
        let returned = record.advanced(by: offset).load(as: attribute_set_t.self)
        offset += MemoryLayout<attribute_set_t>.size

        var name = ""
        if returned.commonattr & nameAttr != 0 {
            guard offset + MemoryLayout<attrreference_t>.size <= length else { return nil }
            let reference = record.advanced(by: offset).load(as: attrreference_t.self)
            let start = offset + Int(reference.attr_dataoffset)
            let byteCount = Int(reference.attr_length)
            guard byteCount >= 1, start >= 0, start + byteCount <= length else { return nil }
            let bytes = UnsafeRawBufferPointer(start: record.advanced(by: start), count: byteCount - 1)
            name = String(decoding: bytes, as: UTF8.self)
            offset += MemoryLayout<attrreference_t>.size
        }
        var type: UInt32 = 0
        if returned.commonattr & objTypeAttr != 0 {
            guard offset + 4 <= length else { return nil }
            type = record.advanced(by: offset).load(as: UInt32.self)
            offset += 4
        }
        var modified: Double?
        if returned.commonattr & modTimeAttr != 0 {
            guard offset + MemoryLayout<timespec>.size <= length else { return nil }
            let time = record.advanced(by: offset).loadUnaligned(as: timespec.self)
            // `URL` reports this timestamp as a `Date`, which round-trips through CFAbsoluteTime
            // (the 2001 epoch). Adding the nanoseconds in Unix time is one ULP away for some
            // values, and that would make every later open look like the file had changed.
            let absolute = Double(time.tv_sec) - 978_307_200 + Double(time.tv_nsec) / 1_000_000_000
            modified = absolute + 978_307_200
            offset += MemoryLayout<timespec>.size
        }
        var size: Int64?
        if returned.fileattr & dataLengthAttr != 0 {
            guard offset + MemoryLayout<Int64>.size <= length else { return nil }
            size = record.advanced(by: offset).loadUnaligned(as: Int64.self)
        }
        return Entry(name: name, type: type, size: size, modified: modified)
    }

    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
