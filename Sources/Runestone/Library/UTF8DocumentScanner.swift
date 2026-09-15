import Foundation

/// UTF-8 walkers that never allocate a `String` / UTF-16 buffer.
enum UTF8DocumentScanner {
    /// UTF-16 code units in `bytes`. Invalid / unexpected continuation bytes count as 1.
    static func utf16Length(ofUTF8 bytes: UnsafeRawBufferPointer) -> Int {
        var utf16 = 0
        var index = 0
        while index < bytes.count {
            let lead = bytes[index]
            if lead < 0x80 {
                utf16 += 1
                index += 1
            } else if lead < 0xC0 {
                utf16 += 1
                index += 1
            } else if lead < 0xE0 {
                utf16 += 1
                index += min(2, bytes.count - index)
            } else if lead < 0xF0 {
                utf16 += 1
                index += min(3, bytes.count - index)
            } else if lead < 0xF8 {
                utf16 += 2
                index += min(4, bytes.count - index)
            } else {
                utf16 += 1
                index += 1
            }
        }
        return utf16
    }

    /// Byte offset of the UTF-16 unit `utf16Offset` within `bytes`. `bytes.count` if past the end.
    /// A low surrogate maps to the same UTF-8 index as its high surrogate (the scalar start).
    static func utf8Offset(forUTF16Offset utf16Offset: Int, in bytes: UnsafeRawBufferPointer) -> Int {
        utf8Position(forUTF16Offset: utf16Offset, in: bytes).utf8Offset
    }

    /// Exclusive UTF-8 end offset for a UTF-16 index. When `utf16Offset` is the low surrogate of a
    /// 4-byte scalar, returns the byte index after that scalar (unlike ``utf8Offset``).
    static func utf8EndOffset(forUTF16Offset utf16Offset: Int, in bytes: UnsafeRawBufferPointer) -> Int {
        let position = utf8Position(forUTF16Offset: utf16Offset, in: bytes)
        var end = position.utf8Offset
        if position.skip > 0, end < bytes.count {
            end += utf8Scalar(at: end, in: bytes).advance
        }
        return end
    }

    /// UTF-8 index of the scalar containing `utf16Offset`. `skip` is 1 when that offset is the
    /// low surrogate of a 4-byte scalar, otherwise 0.
    static func utf8Position(forUTF16Offset utf16Offset: Int, in bytes: UnsafeRawBufferPointer) -> (utf8Offset: Int, skip: Int) {
        if utf16Offset <= 0 {
            return (0, 0)
        }
        var utf16 = 0
        var index = 0
        while index < bytes.count {
            if utf16 >= utf16Offset {
                return (index, 0)
            }
            let (units, advance) = utf8Scalar(at: index, in: bytes)
            if utf16 + units > utf16Offset {
                return (index, utf16Offset - utf16)
            }
            utf16 += units
            index += advance
        }
        return (bytes.count, 0)
    }

    /// Appends `length` UTF-16 units starting at `utf16Offset`. A range that starts or ends
    /// inside a surrogate pair emits the unpaired unit rather than dropping or duplicating it.
    static func appendUTF16Units(
        from bytes: UnsafeRawBufferPointer,
        utf16Offset: Int,
        length: Int,
        into result: inout [unichar]
    ) {
        guard length > 0 else {
            return
        }
        let start = utf8Position(forUTF16Offset: utf16Offset, in: bytes)
        let utf8End = utf8EndOffset(forUTF16Offset: utf16Offset + length, in: bytes)
        guard utf8End > start.utf8Offset else {
            return
        }
        let sliceEnd = min(utf8End, bytes.count)
        let slice = UnsafeRawBufferPointer(rebasing: bytes[start.utf8Offset..<sliceEnd])
        guard let string = String(bytes: Data(slice), encoding: .utf8) else {
            return
        }
        let decoded = Array(string.utf16)
        let drop = min(start.skip, decoded.count)
        let take = min(length, decoded.count - drop)
        guard take > 0 else {
            return
        }
        result.append(contentsOf: decoded[drop..<(drop + take)])
    }

    private static func utf8Scalar(at index: Int, in bytes: UnsafeRawBufferPointer) -> (units: Int, advance: Int) {
        let lead = bytes[index]
        if lead < 0x80 {
            return (1, 1)
        }
        if lead < 0xC0 {
            return (1, 1)
        }
        if lead < 0xE0 {
            return (1, min(2, bytes.count - index))
        }
        if lead < 0xF0 {
            return (1, min(3, bytes.count - index))
        }
        if lead < 0xF8 {
            return (2, min(4, bytes.count - index))
        }
        return (1, 1)
    }

    static func stripBOM(from bytes: UnsafeRawBufferPointer) -> UnsafeRawBufferPointer {
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            return UnsafeRawBufferPointer(rebasing: bytes.dropFirst(3))
        }
        return bytes
    }

    /// `(utf8Offset, utf16Offset, lineCount)` triples on the original mapping, for O(log n)+64KB
    /// UTF-16→UTF-8 conversion and line-feed counts inside a large original piece.
    struct Checkpoint {
        var utf8Offset: Int
        var utf16Offset: Int
        /// Number of line delimiters fully ended before `utf8Offset`.
        var lineCount: Int
    }

    struct Scan {
        var lineMetrics: [LineMetric]
        var checkpoints: [Checkpoint]
        var utf16Length: Int
        var lineFeedCount: Int
        var longestLineUTF16: Int
        var longestLineIndex: Int
        var isValid: Bool
    }

    static let checkpointStride = 64 * 1024

    static func scan(_ bytes: UnsafeRawBufferPointer) -> Scan {
        var lines: [LineMetric] = []
        var scan = scan(bytes, onLine: { lines.append($0) }, onProgress: nil)
        scan.lineMetrics = lines
        return scan
    }

    /// Walk `bytes` once. `onLine` receives each completed line (including the trailing line with
    /// no delimiter). `onProgress` is called with the current byte index at checkpoint boundaries
    /// so a loader can remap already-scanned pages.
    static func scan(
        _ bytes: UnsafeRawBufferPointer,
        onLine: ((LineMetric) -> Void)?,
        onProgress: ((Int) -> Void)?
    ) -> Scan {
        var checkpoints: [Checkpoint] = [Checkpoint(utf8Offset: 0, utf16Offset: 0, lineCount: 0)]
        var currentUTF16 = 0
        var totalUTF16 = 0
        var lineFeedCount = 0
        var longestLineUTF16 = 0
        var longestLineIndex = 0
        var lineIndex = 0
        var index = 0
        var isValid = true
        let count = bytes.count
        func finishLine(_ metric: LineMetric) {
            if metric.totalLength > longestLineUTF16 {
                longestLineUTF16 = metric.totalLength
                longestLineIndex = lineIndex
            }
            onLine?(metric)
            lineIndex += 1
            if metric.delimiterLength > 0 {
                lineFeedCount += 1
            }
        }
        while index < count {
            if index - checkpoints[checkpoints.count - 1].utf8Offset >= checkpointStride {
                checkpoints.append(Checkpoint(
                    utf8Offset: index,
                    utf16Offset: totalUTF16 + currentUTF16,
                    lineCount: lineFeedCount
                ))
                onProgress?(index)
            }
            let byte = bytes[index]
            if byte == 0x0A {
                finishLine(LineMetric(totalLength: currentUTF16 + 1, delimiterLength: 1))
                totalUTF16 += currentUTF16 + 1
                currentUTF16 = 0
                index += 1
            } else if byte == 0x0D {
                if index + 1 < count && bytes[index + 1] == 0x0A {
                    finishLine(LineMetric(totalLength: currentUTF16 + 2, delimiterLength: 2))
                    totalUTF16 += currentUTF16 + 2
                    currentUTF16 = 0
                    index += 2
                } else {
                    finishLine(LineMetric(totalLength: currentUTF16 + 1, delimiterLength: 1))
                    totalUTF16 += currentUTF16 + 1
                    currentUTF16 = 0
                    index += 1
                }
            } else if byte == 0xC2, index + 1 < count, bytes[index + 1] == 0x85 {
                finishLine(LineMetric(totalLength: currentUTF16 + 1, delimiterLength: 1))
                totalUTF16 += currentUTF16 + 1
                currentUTF16 = 0
                index += 2
            } else if byte == 0xE2, index + 2 < count, bytes[index + 1] == 0x80,
                      bytes[index + 2] == 0xA8 || bytes[index + 2] == 0xA9 {
                finishLine(LineMetric(totalLength: currentUTF16 + 1, delimiterLength: 1))
                totalUTF16 += currentUTF16 + 1
                currentUTF16 = 0
                index += 3
            } else {
                let lead = byte
                let needed: Int
                let units: Int
                if lead < 0x80 {
                    needed = 0
                    units = 1
                } else if lead < 0xC0 {
                    isValid = false
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
                    isValid = false
                    needed = 0
                    units = 1
                }
                if needed > 0 {
                    if index + needed >= count {
                        isValid = false
                    } else {
                        for offset in 1...needed where bytes[index + offset] & 0xC0 != 0x80 {
                            isValid = false
                        }
                    }
                }
                currentUTF16 += units
                index += min(1 + needed, count - index)
            }
        }
        finishLine(LineMetric(totalLength: currentUTF16, delimiterLength: 0))
        totalUTF16 += currentUTF16
        onProgress?(count)
        return Scan(
            lineMetrics: [],
            checkpoints: checkpoints,
            utf16Length: totalUTF16,
            lineFeedCount: lineFeedCount,
            longestLineUTF16: longestLineUTF16,
            longestLineIndex: longestLineIndex,
            isValid: isValid
        )
    }

    /// Line metrics matching ``LineBreakAccumulator`` / `NSString.getLineStart` (LF, CR, CRLF, NEL, LS, PS).
    static func lineMetrics(in bytes: UnsafeRawBufferPointer) -> [LineMetric] {
        scan(bytes).lineMetrics
    }

    static func isValidUTF8(_ bytes: UnsafeRawBufferPointer) -> Bool {
        scan(bytes, onLine: nil, onProgress: nil).isValid
    }

    /// Number of line delimiters in `bytes` (CRLF counts as one).
    static func lineFeedCount(in bytes: UnsafeRawBufferPointer) -> Int {
        var count = 0
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x0A {
                count += 1
                index += 1
            } else if byte == 0x0D {
                if index + 1 < bytes.count && bytes[index + 1] == 0x0A {
                    index += 2
                } else {
                    index += 1
                }
                count += 1
            } else if byte == 0xC2, index + 1 < bytes.count, bytes[index + 1] == 0x85 {
                count += 1
                index += 2
            } else if byte == 0xE2, index + 2 < bytes.count, bytes[index + 1] == 0x80,
                      bytes[index + 2] == 0xA8 || bytes[index + 2] == 0xA9 {
                count += 1
                index += 3
            } else if byte < 0x80 {
                index += 1
            } else if byte < 0xC0 {
                index += 1
            } else if byte < 0xE0 {
                index += min(2, bytes.count - index)
            } else if byte < 0xF0 {
                index += min(3, bytes.count - index)
            } else if byte < 0xF8 {
                index += min(4, bytes.count - index)
            } else {
                index += 1
            }
        }
        return count
    }
}
