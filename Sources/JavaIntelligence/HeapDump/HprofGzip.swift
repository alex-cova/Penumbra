import Foundation
import zlib

/// Decompresses a gzip'd heap dump (`jcmd GC.heap_dump -gz`, or `gzip x.hprof`) to a plain one.
/// HotSpot writes one gzip member per chunk, back to back, so every member is read in turn. The
/// system zlib does the work in its gzip mode (`16 + MAX_WBITS`): it parses each header, checks each
/// trailer's CRC-32 and length, and stops exactly at a member's end, so the next one starts there.
/// (Apple's Compression framework reads past the end of a DEFLATE stream and loses that boundary.)
/// Streams in 1 MB pieces; memory stays flat.
public enum HprofGzip {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notGzip
        case corrupt(String)
        case io(String)

        public var description: String {
            switch self {
            case .notGzip: return "The file is not gzip-compressed."
            case .corrupt(let what): return "The compressed heap dump is damaged: \(what)."
            case .io(let what): return "Could not decompress the heap dump: \(what)."
            }
        }
    }

    /// The gzip magic, `1F 8B`.
    public static func isGzip(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url), let head = try? handle.read(upToCount: 2) else { return false }
        try? handle.close()
        return head.count == 2 && head[head.startIndex] == 0x1F && head[head.startIndex + 1] == 0x8B
    }

    /// Decompresses `source` into `destination` (written beside it under a temporary name, then
    /// renamed, so a cancelled or failed run leaves nothing that looks finished).
    /// `progress` gets the share of the compressed file read, 0...1.
    public static func decompress(
        _ source: URL, to destination: URL, progress: @Sendable (Double) -> Void = { _ in }
    ) throws {
        guard isGzip(at: source) else { throw Failure.notGzip }
        let input: FileHandle
        do { input = try FileHandle(forReadingFrom: source) } catch { throw Failure.io(error.localizedDescription) }
        defer { try? input.close() }
        let total = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int64) ?? 0
        let partial = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).partial")
        try? FileManager.default.removeItem(at: partial)
        guard FileManager.default.createFile(atPath: partial.path, contents: nil),
              let output = FileHandle(forWritingAtPath: partial.path) else {
            throw Failure.io("cannot create \(partial.lastPathComponent)")
        }
        var finished = false
        defer {
            try? output.close()
            if !finished { try? FileManager.default.removeItem(at: partial) }
        }

        var stream = z_stream()
        guard inflateInit2_(&stream, 16 + MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw Failure.io("zlib did not start")
        }
        defer { inflateEnd(&stream) }
        let capacity = 1 << 20
        let outputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { outputBuffer.deallocate() }
        var pending = Data()       // compressed bytes not consumed yet
        var read: Int64 = 0
        var atEnd = false
        var members = 0
        var inMember = false
        var pieces = 0
        func failure(_ status: Int32) -> Failure {
            let message = stream.msg.map { String(cString: $0) } ?? "zlib error \(status)"
            if message.contains("data check") || message.contains("length check") {
                return .corrupt("member \(members + 1) fails its checksum")
            }
            return .corrupt(message)
        }

        // Each read hands back a buffer the system autoreleases: without a pool per piece they
        // would all live until the end, a whole dump's worth of memory.
        while true {
            let stop = try autoreleasepool { () throws -> Bool in
                if pending.isEmpty, !atEnd {
                    let chunk: Data?
                    do { chunk = try input.read(upToCount: 1 << 20) } catch { throw Failure.io(error.localizedDescription) }
                    if let chunk, !chunk.isEmpty {
                        pending = chunk
                        read += Int64(chunk.count)
                    } else {
                        atEnd = true
                    }
                }
                if pending.isEmpty {
                    if inMember { throw Failure.corrupt("the file ends inside a member") }
                    return true
                }
                inMember = true
                var status: Int32 = Z_OK
                var produced = 0
                var used = 0
                pending.withUnsafeMutableBytes { raw in
                    stream.next_in = raw.baseAddress!.assumingMemoryBound(to: Bytef.self)
                    stream.avail_in = uInt(raw.count)
                    stream.next_out = outputBuffer
                    stream.avail_out = uInt(capacity)
                    status = inflate(&stream, Z_NO_FLUSH)
                    produced = capacity - Int(stream.avail_out)
                    used = raw.count - Int(stream.avail_in)
                }
                pending.removeFirst(used)
                if produced > 0 { output.write(Data(bytesNoCopy: outputBuffer, count: produced, deallocator: .none)) }
                switch status {
                case Z_STREAM_END:
                    members += 1
                    inMember = false
                    guard inflateReset(&stream) == Z_OK else { throw Failure.io("zlib did not reset") }
                case Z_OK:
                    break
                case Z_BUF_ERROR where produced == 0 && used == 0:
                    // Needs more input than is pending: read on (or, at the end, the file is cut).
                    if atEnd { throw Failure.corrupt("the file ends inside a member") }
                    var more: Data?
                    do { more = try input.read(upToCount: 1 << 20) } catch { throw Failure.io(error.localizedDescription) }
                    if let more, !more.isEmpty {
                        pending.append(more)
                        read += Int64(more.count)
                    } else {
                        atEnd = true
                    }
                default:
                    throw failure(status)
                }
                pieces += 1
                if pieces & 15 == 0 {
                    try Task.checkCancellation()
                    progress(total > 0 ? Double(read) / Double(total) : 0)
                }
                return false
            }
            if stop { break }
        }
        guard members > 0 else { throw Failure.corrupt("no gzip member") }
        do {
            try output.synchronize()
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            throw Failure.io(error.localizedDescription)
        }
        finished = true
        progress(1)
    }
}
