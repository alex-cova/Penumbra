import Darwin
import Foundation

/// Errors thrown by ``TextViewState/load(contentsOf:theme:language:languageProvider:parsePolicy:encoding:io:progress:)``.
public enum DocumentLoadError: Error, Equatable {
    /// The load task was cancelled.
    case cancelled
    /// Only UTF-8 is supported for chunked loading.
    case unsupportedEncoding
    /// A byte sequence was not valid in the requested encoding.
    case invalidEncoding
    /// A private clone could not be created or mapped.
    case fileChanged
}

/// How ``TextViewState/load(contentsOf:theme:language:languageProvider:parsePolicy:encoding:io:progress:)``
/// pulls bytes off disk.
///
/// Both strategies produce a live file-backed ``PieceTree`` (private clone or copied temp, then
/// `mmap`). The mapping is kept as the document — it is not copied into an `NSMutableString`.
public enum DocumentLoadIO: Sendable, Equatable {
    /// Copy into a private temp file, then `mmap` the temp.
    case streamed
    /// APFS `clonefile` (copy fallback) into a private inode, then `mmap`.
    case memoryMapped
}

/// Chunked UTF-8 file reader that maps a private clone and records line metrics without UTF-16 text.
enum DocumentLoader {
    /// Overridable in tests so UTF-8 and CRLF sequences can be forced across chunk boundaries.
    nonisolated(unsafe) static var chunkByteCount = 1_048_576

    struct Result {
        let pieceTree: PieceTree
        let packedIndex: PackedLineIndex
    }

    static func load(
        from url: URL,
        encoding: String.Encoding,
        io: DocumentLoadIO,
        estimatedLineHeight: CGFloat,
        progress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> Result {
        guard encoding == .utf8 else {
            throw DocumentLoadError.unsupportedEncoding
        }
        if Task.isCancelled {
            throw DocumentLoadError.cancelled
        }
        switch io {
        case .memoryMapped:
            if let mapped = try await loadMapped(from: url, estimatedLineHeight: estimatedLineHeight, progress: progress) {
                return mapped
            }
            return try await loadStreamed(from: url, estimatedLineHeight: estimatedLineHeight, progress: progress)
        case .streamed:
            return try await loadStreamed(from: url, estimatedLineHeight: estimatedLineHeight, progress: progress)
        }
    }

    private static func loadMapped(
        from url: URL,
        estimatedLineHeight: CGFloat,
        progress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> Result? {
        guard let mapping = FileMapping.openPrivateClone(of: url) else {
            return nil
        }
        return try await scan(mapping: mapping, estimatedLineHeight: estimatedLineHeight, progress: progress)
    }

    private static func loadStreamed(
        from url: URL,
        estimatedLineHeight: CGFloat,
        progress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> Result {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("penumbra-stream-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: url, to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        guard let mapping = FileMapping(url: tempURL) else {
            throw DocumentLoadError.fileChanged
        }
        try? FileManager.default.removeItem(at: tempURL)
        return try await scan(mapping: mapping, estimatedLineHeight: estimatedLineHeight, progress: progress)
    }

    private static let keepResidentBytes = 64 * 1024
    private static let discardStride = 1_048_576

    private static func scan(
        mapping: FileMapping,
        estimatedLineHeight: CGFloat,
        progress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> Result {
        if mapping.hasBeenTruncated {
            mapping.release()
            throw DocumentLoadError.fileChanged
        }
        let raw = mapping.bytes()
        let stripped = UTF8DocumentScanner.stripBOM(from: raw)
        let packed = PackedLineIndex(estimatedLineHeight: estimatedLineHeight)
        packed.prepareStreamingRebuild(estimatedLineHeight: estimatedLineHeight)
        let bomBytes = raw.count - stripped.count
        var lastRemapped = 0
        let scanned = UTF8DocumentScanner.scan(stripped, onLine: { metric in
            packed.appendStreamingLine(utf16Length: metric.totalLength, delimiterLength: metric.delimiterLength)
        }, onProgress: { byteIndex in
            let mappingOffset = byteIndex + bomBytes
            if mappingOffset - lastRemapped >= discardStride {
                mapping.remapPages(from: keepResidentBytes, upTo: mappingOffset)
                lastRemapped = mappingOffset
            }
        })
        packed.finishStreamingRebuild()
        if !scanned.isValid {
            mapping.release()
            throw DocumentLoadError.invalidEncoding
        }
        if Task.isCancelled {
            mapping.release()
            throw DocumentLoadError.cancelled
        }
        await Task.yield()
        progress?(Int64(mapping.size), Int64(mapping.size))
        mapping.replaceMapping(keepingFirst: keepResidentBytes)
        let tree = PieceTree(mapping: mapping, scan: scanned)
        return Result(pieceTree: tree, packedIndex: packed)
    }

    /// Length of the longest prefix of `data` that ends on a complete UTF-8 sequence.
    static func completeUTF8PrefixLength(in data: Data) -> Int {
        data.withUnsafeBytes { completeUTF8PrefixLength(in: $0) }
    }

    static func completeUTF8PrefixLength(in bytes: UnsafeRawBufferPointer) -> Int {
        guard !bytes.isEmpty else {
            return 0
        }
        var index = bytes.count - 1
        var continuationCount = 0
        while index >= 0 && bytes[index] & 0xC0 == 0x80 {
            continuationCount += 1
            if continuationCount > 3 {
                return bytes.count
            }
            index -= 1
        }
        guard index >= 0 else {
            return 0
        }
        let lead = bytes[index]
        let needed: Int
        if lead < 0x80 {
            needed = 0
        } else if lead & 0xE0 == 0xC0 {
            needed = 1
        } else if lead & 0xF0 == 0xE0 {
            needed = 2
        } else if lead & 0xF8 == 0xF0 {
            needed = 3
        } else {
            return bytes.count
        }
        if continuationCount < needed {
            return index
        }
        return bytes.count
    }
}

/// Walks UTF-16 code units, matching ``NewLineFinder`` / `NSString.getLineStart` (LF, CR, CRLF).
struct LineBreakAccumulator {
    private var lines: [LineMetric] = []
    private var currentLineUTF16 = 0
    private var pendingCR = false

    mutating func consume(_ chunk: NSString) {
        var index = 0
        let length = chunk.length
        if pendingCR {
            pendingCR = false
            if length > 0 && chunk.character(at: 0) == 0x000A {
                lines.append(LineMetric(totalLength: currentLineUTF16 + 2, delimiterLength: 2))
                currentLineUTF16 = 0
                index = 1
            } else {
                lines.append(LineMetric(totalLength: currentLineUTF16 + 1, delimiterLength: 1))
                currentLineUTF16 = 0
            }
        }
        while index < length {
            let unit = chunk.character(at: index)
            if unit == 0x000A || unit == 0x0085 || unit == 0x2028 || unit == 0x2029 {
                lines.append(LineMetric(totalLength: currentLineUTF16 + 1, delimiterLength: 1))
                currentLineUTF16 = 0
            } else if unit == 0x000D {
                if index + 1 < length && chunk.character(at: index + 1) == 0x000A {
                    lines.append(LineMetric(totalLength: currentLineUTF16 + 2, delimiterLength: 2))
                    currentLineUTF16 = 0
                    index += 1
                } else if index + 1 == length {
                    pendingCR = true
                } else {
                    lines.append(LineMetric(totalLength: currentLineUTF16 + 1, delimiterLength: 1))
                    currentLineUTF16 = 0
                }
            } else {
                currentLineUTF16 += 1
            }
            index += 1
        }
    }

    mutating func finish() -> [LineMetric] {
        if pendingCR {
            lines.append(LineMetric(totalLength: currentLineUTF16 + 1, delimiterLength: 1))
            currentLineUTF16 = 0
            pendingCR = false
        }
        lines.append(LineMetric(totalLength: currentLineUTF16, delimiterLength: 0))
        return lines
    }
}
