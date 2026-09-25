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
        let count = bytes.count
        while index < count {
            if utf16 >= utf16Offset {
                return (index, 0)
            }
            // Eight ASCII bytes are eight UTF-16 units: skip them a word at a time. Callers start
            // from a checkpoint up to 64KB back, so this loop runs for every line substring.
            if utf16Offset - utf16 >= 8, index + 8 <= count, let base = bytes.baseAddress,
               base.loadUnaligned(fromByteOffset: index, as: UInt64.self) & 0x8080_8080_8080_8080 == 0 {
                utf16 += 8
                index += 8
                continue
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
        // Resolve the end from the start's scalar instead of rescanning from byte 0.
        let scalarStartUTF16 = utf16Offset - start.skip
        let tail = UnsafeRawBufferPointer(rebasing: bytes[start.utf8Offset...])
        let utf8End = start.utf8Offset
            + utf8EndOffset(forUTF16Offset: utf16Offset + length - scalarStartUTF16, in: tail)
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

    /// Spacing of ``Checkpoint``s, and the byte bound on a single add-buffer piece.
    ///
    /// Overridable in tests so piece boundaries — a split scalar, a halved CRLF — can be forced
    /// without multi-megabyte fixtures, the same way ``DocumentLoader/chunkByteCount`` is. Nothing
    /// in production changes it.
    nonisolated(unsafe) static var checkpointStride = 64 * 1024

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
        onProgress: ((Int) -> Void)?,
        checkpointStride: Int = UTF8DocumentScanner.checkpointStride
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

    // MARK: - Resumable line scan

    /// Carry state for scanning one document that arrives in several buffers, e.g. ``PieceTree``
    /// pieces.
    ///
    /// ``scan(_:onLine:onProgress:checkpointStride:)`` cannot be applied per buffer because it
    /// looks ahead within its own buffer (`bytes[index + 1] == 0x0A`) and always emits a trailing
    /// delimiter-less line. This holds everything a buffer boundary can interrupt so
    /// ``scanLines(_:state:onLine:)`` can be called once per buffer instead.
    struct LineScanState {
        /// UTF-16 units of the line currently in progress. It has not been emitted yet.
        fileprivate var currentUTF16 = 0
        /// A CR ended the previous buffer. It pairs into a CRLF only if the next buffer opens with LF.
        fileprivate var pendingCR = false
        /// Leading bytes of a multi-byte scalar whose continuation bytes fall in a later buffer.
        ///
        /// `PieceTree` boundaries are scalar-aligned today (`insert` skips continuation bytes and
        /// `split(atUTF16:)` resolves to scalar starts), but carrying the partial sequence keeps
        /// the scanner correct for an arbitrary split, including a NEL/LS/PS delimiter cut in half.
        fileprivate var partialScalar: [UInt8] = []
        fileprivate var sawInvalidByte = false

        /// Whether every sequence seen so far was well-formed UTF-8.
        var isValid: Bool {
            !sawInvalidByte
        }

        init() {}
    }

    /// Scans one buffer of a larger document, emitting every line that *completes* inside it.
    ///
    /// The in-progress line stays in `state` rather than being emitted, so consecutive buffers can
    /// be fed in order. Call ``finishLineScan(state:onLine:)`` once after the last buffer to emit
    /// the document's final, delimiter-less line.
    ///
    /// An empty buffer is a no-op: finalizing a pending CR here would break a CRLF whose LF is in a
    /// later piece.
    static func scanLines(
        _ bytes: UnsafeRawBufferPointer,
        state: inout LineScanState,
        onLine: (LineMetric) -> Void
    ) {
        let count = bytes.count
        guard count > 0 else {
            return
        }
        var index = 0
        if state.pendingCR {
            state.pendingCR = false
            if bytes[0] == 0x0A {
                emitLine(&state, delimiterUTF16: 2, delimiterLength: 2, onLine)
                index = 1
            } else {
                emitLine(&state, delimiterUTF16: 1, delimiterLength: 1, onLine)
            }
        }
        if !state.partialScalar.isEmpty {
            index = completePartialScalar(bytes, from: index, state: &state, onLine: onLine)
        }
        while index < count {
            let byte = bytes[index]
            if byte == 0x0A {
                emitLine(&state, delimiterUTF16: 1, delimiterLength: 1, onLine)
                index += 1
            } else if byte == 0x0D {
                if index + 1 < count {
                    if bytes[index + 1] == 0x0A {
                        emitLine(&state, delimiterUTF16: 2, delimiterLength: 2, onLine)
                        index += 2
                    } else {
                        emitLine(&state, delimiterUTF16: 1, delimiterLength: 1, onLine)
                        index += 1
                    }
                } else {
                    // Last byte of this buffer. The LF that would pair with it may open the next one.
                    state.pendingCR = true
                    index += 1
                }
            } else if let shape = sequenceShape(lead: byte) {
                if shape.length == 1 {
                    state.currentUTF16 += 1
                    index += 1
                    continue
                }
                if index + shape.length > count {
                    state.partialScalar.removeAll(keepingCapacity: true)
                    for offset in index..<count {
                        state.partialScalar.append(bytes[offset])
                    }
                    return
                }
                let second = bytes[index + 1]
                let third = shape.length > 2 ? bytes[index + 2] : 0
                for offset in (index + 1)..<(index + shape.length) where bytes[offset] & 0xC0 != 0x80 {
                    state.sawInvalidByte = true
                }
                if isDelimiterSequence(length: shape.length, byte, second, third) {
                    emitLine(&state, delimiterUTF16: 1, delimiterLength: 1, onLine)
                } else {
                    state.currentUTF16 += shape.units
                }
                index += shape.length
            } else {
                // Unexpected continuation byte or 0xF8+. Counts as one UTF-16 unit, as `scan` does.
                state.sawInvalidByte = true
                state.currentUTF16 += 1
                index += 1
            }
        }
    }

    /// Emits the document's final line, which by definition has no delimiter. Call once, after the
    /// last ``scanLines(_:state:onLine:)`` call.
    static func finishLineScan(
        state: inout LineScanState,
        onLine: (LineMetric) -> Void
    ) {
        if !state.partialScalar.isEmpty {
            // Truncated sequence at end of document. `scan` counts the lead byte's units and flags
            // the document invalid; match that rather than dropping the partial scalar.
            state.currentUTF16 += sequenceShape(lead: state.partialScalar[0])?.units ?? 1
            state.partialScalar.removeAll(keepingCapacity: false)
            state.sawInvalidByte = true
        }
        if state.pendingCR {
            state.pendingCR = false
            emitLine(&state, delimiterUTF16: 1, delimiterLength: 1, onLine)
        }
        onLine(LineMetric(totalLength: state.currentUTF16, delimiterLength: 0))
        state.currentUTF16 = 0
    }

    /// Consumes the continuation bytes of a scalar carried over from the previous buffer and
    /// returns the index to resume plain scanning from.
    private static func completePartialScalar(
        _ bytes: UnsafeRawBufferPointer,
        from start: Int,
        state: inout LineScanState,
        onLine: (LineMetric) -> Void
    ) -> Int {
        guard let shape = sequenceShape(lead: state.partialScalar[0]) else {
            state.partialScalar.removeAll(keepingCapacity: true)
            state.sawInvalidByte = true
            return start
        }
        var index = start
        while state.partialScalar.count < shape.length, index < bytes.count {
            let byte = bytes[index]
            if byte & 0xC0 != 0x80 {
                state.sawInvalidByte = true
            }
            state.partialScalar.append(byte)
            index += 1
        }
        guard state.partialScalar.count == shape.length else {
            // This buffer did not finish the sequence either. Keep waiting.
            return index
        }
        let sequence = state.partialScalar
        state.partialScalar.removeAll(keepingCapacity: true)
        let third = sequence.count > 2 ? sequence[2] : 0
        if isDelimiterSequence(length: shape.length, sequence[0], sequence[1], third) {
            emitLine(&state, delimiterUTF16: 1, delimiterLength: 1, onLine)
        } else {
            state.currentUTF16 += shape.units
        }
        return index
    }

    private static func emitLine(
        _ state: inout LineScanState,
        delimiterUTF16: Int,
        delimiterLength: Int,
        _ onLine: (LineMetric) -> Void
    ) {
        onLine(LineMetric(totalLength: state.currentUTF16 + delimiterUTF16, delimiterLength: delimiterLength))
        state.currentUTF16 = 0
    }

    /// Bytes a sequence with this lead byte occupies, and the UTF-16 units it contributes.
    /// `nil` for a byte that cannot start a sequence.
    private static func sequenceShape(lead: UInt8) -> (length: Int, units: Int)? {
        if lead < 0x80 {
            return (1, 1)
        }
        if lead < 0xC0 {
            return nil
        }
        if lead < 0xE0 {
            return (2, 1)
        }
        if lead < 0xF0 {
            return (3, 1)
        }
        if lead < 0xF8 {
            return (4, 2)
        }
        return nil
    }

    /// Whether a sequence is NEL (U+0085), LS (U+2028), or PS (U+2029) — the non-ASCII line
    /// delimiters `NSString.getLineStart` recognizes. Bytes are passed positionally so the hot path
    /// stays allocation-free.
    private static func isDelimiterSequence(length: Int, _ first: UInt8, _ second: UInt8, _ third: UInt8) -> Bool {
        if length == 2 {
            return first == 0xC2 && second == 0x85
        }
        if length == 3 {
            return first == 0xE2 && second == 0x80 && (third == 0xA8 || third == 0xA9)
        }
        return false
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
