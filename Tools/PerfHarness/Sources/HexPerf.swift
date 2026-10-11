import Darwin
import Foundation
import HexKit

/// Release timings for the hex editor. Creates its own sparse file. No path argument.
enum HexPerf {
    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    static func run(command: String, arguments: [String]) throws {
        let requested = parseSize(flagValue("--size", in: arguments))
        let (url, size) = try createSparse(preferred: requested)
        defer { try? FileManager.default.removeItem(at: url) }

        var failed: [String] = []
        let openStart = ContinuousClock.now
        let source = try FileByteSource(url: url)
        var document = HexDocument(source: source)
        let openMs = milliseconds(since: openStart)
        print("command=\(command)")
        print("file_bytes=\(size)")
        print("open_ms=\(format(openMs))")
        if openMs >= 50 { failed.append("open_ms \(format(openMs)) >= 50") }

        let scrollMs = timeScroll(document: document)
        print("scroll_step_ms=\(format(scrollMs))")
        if scrollMs >= 4 { failed.append("scroll_step_ms \(format(scrollMs)) >= 4") }

        let seekMs = timeSeek(document: document, size: size)
        print("seek_ms=\(format(seekMs))")
        if seekMs >= 16 { failed.append("seek_ms \(format(seekMs)) >= 16") }

        let needle = Array("HEXNEEDLE01".utf8)
        let pattern = HexPattern(bytes: needle)
        let found = try HexSearch.scan(in: source, pattern: pattern, from: 0, limit: 1)
        let match = found.matches.first?.lowerBound ?? -1
        print("match_offset=\(match)")
        if match != 4096 { failed.append("match_offset \(match) != 4096") }

        let searchStart = ContinuousClock.now
        _ = try HexSearch.scan(in: source, pattern: HexPattern(bytes: [0xFF]), from: 0, limit: HexSearch.defaultLimit)
        let searchSeconds = seconds(since: searchStart)
        let megabytesPerSecond = searchSeconds > 0 ? Double(size) / searchSeconds / 1_000_000 : 0
        print("search_mb_s=\(format(megabytesPerSecond))")
        if megabytesPerSecond < 500 { failed.append("search_mb_s \(format(megabytesPerSecond)) < 500") }

        let keystrokeUs = try timeKeystroke(&document)
        print("keystroke_us=\(format(keystrokeUs))")
        print("piece_count=\(document.pieceCount)")
        if keystrokeUs >= 1000 { failed.append("keystroke_us \(format(keystrokeUs)) >= 1000") }
        if document.pieceCount != 4096 { failed.append("piece_count \(document.pieceCount) != 4096") }

        print("cached_pages=\(source.cachedPageCount)")
        source.close()
        if !failed.isEmpty {
            throw Failure(description: failed.joined(separator: "; "))
        }
    }

    /// One viewport: 120 rows of 64 bytes, read and formatted the way a frame is.
    private static func timeScroll(document: HexDocument) -> Double {
        let width = 64
        let rows = 120
        let metrics = HexRowMetrics(bytesPerRow: width, groupSize: 8, charWidth: 8, offsetDigits: 8)
        func frame() {
            var buffer = [UInt8](repeating: 0, count: width)
            for row in 0..<rows {
                let start = Int64(row * width)
                _ = buffer.withUnsafeMutableBytes { document.read(start..<start + Int64(width), into: $0) }
                _ = HexLayout.formatOffset(start, digits: metrics.offsetDigits, base: .hexadecimal, uppercase: true)
                for byte in buffer {
                    _ = HexLayout.formatHex(byte, uppercase: true)
                    _ = HexByteClass.classify(byte)
                }
                _ = HexLayout.rowText(buffer, encoding: .windows1252)
            }
        }
        frame()
        let start = ContinuousClock.now
        frame()
        return milliseconds(since: start)
    }

    private static func timeSeek(document: HexDocument, size: Int64) -> Double {
        let width = 64
        let startOffset = max(0, size - Int64(width))
        var buffer = [UInt8](repeating: 0, count: width)
        let start = ContinuousClock.now
        _ = buffer.withUnsafeMutableBytes { document.read(startOffset..<startOffset + Int64(width), into: $0) }
        _ = HexLayout.formatOffset(startOffset, digits: 16, base: .hexadecimal, uppercase: true)
        return milliseconds(since: start)
    }

    /// 4,096 pieces on a file larger than 32 MB, then one overwrite that does not add a piece.
    private static func timeKeystroke(_ document: inout HexDocument) throws -> Double {
        guard document.count > HexDocument.compactionSizeLimit else {
            throw Failure(description: "file is not larger than 32 MB")
        }
        document.insert(at: 0, bytes: [0x01])
        guard document.pieceCount == 2 else {
            throw Failure(description: "insert did not make 2 pieces (\(document.pieceCount))")
        }
        let origin = Int64(1_000_000)
        for index in 0..<2047 {
            let at = origin + Int64(index * 2)
            guard at + 1 < document.count else {
                throw Failure(description: "keystroke recipe ran past the file")
            }
            document.overwrite(at: at, bytes: [0xAB])
        }
        guard document.pieceCount == 4096 else {
            throw Failure(description: "recipe made \(document.pieceCount) pieces, not 4096")
        }
        let start = ContinuousClock.now
        document.overwrite(at: 0, bytes: [0x02])
        let elapsed = microseconds(since: start)
        return elapsed
    }

    private static func createSparse(preferred: Int64?) throws -> (URL, Int64) {
        var candidates: [Int64] = [4 << 30, 1 << 30, 256 << 20, 64 << 20]
        if let preferred {
            candidates.removeAll { $0 > preferred }
            if !candidates.contains(preferred) { candidates.insert(preferred, at: 0) }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hex-perf-\(UUID().uuidString).bin")
        let fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw Failure(description: "open failed") }
        defer { Darwin.close(fd) }
        let needle = Array("HEXNEEDLE01".utf8)
        for size in candidates {
            if ftruncate(fd, off_t(size)) != 0 { continue }
            let wrote = needle.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return pwrite(fd, base, needle.count, 4096)
            }
            guard wrote == needle.count else { continue }
            return (url, size)
        }
        throw Failure(description: "could not create a sparse file larger than the page cache")
    }

    private static func parseSize(_ text: String?) -> Int64? {
        guard var text = text?.lowercased(), !text.isEmpty else { return nil }
        let multiplier: Int64
        if text.hasSuffix("gb") {
            multiplier = 1 << 30
            text.removeLast(2)
        } else if text.hasSuffix("mb") {
            multiplier = 1 << 20
            text.removeLast(2)
        } else {
            multiplier = 1
        }
        guard let value = Int64(text) else { return nil }
        return value * multiplier
    }

    private static func flagValue(_ name: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: ContinuousClock.now)
        let seconds = Double(duration.components.seconds)
        let fraction = Double(duration.components.attoseconds) / 1e18
        return (seconds + fraction) * 1000
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        milliseconds(since: start) / 1000
    }

    private static func microseconds(since start: ContinuousClock.Instant) -> Double {
        milliseconds(since: start) * 1000
    }

    private static func format(_ value: Double) -> String { String(format: "%.3f", value) }
}
