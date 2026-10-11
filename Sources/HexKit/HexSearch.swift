import Darwin
import Foundation

public enum HexSearchDirection: Sendable {
    case forward
    case backward
}

/// A byte pattern. `wildcard[i]` skips comparison of `bytes[i]` (a `??` nibble pair).
public struct HexPattern: Sendable, Equatable {
    public var bytes: [UInt8]
    public var wildcard: [Bool]
    public var caseInsensitive: Bool

    public init(bytes: [UInt8], wildcard: [Bool]? = nil, caseInsensitive: Bool = false) {
        self.bytes = bytes
        if let wildcard, wildcard.count == bytes.count {
            self.wildcard = wildcard
        } else {
            self.wildcard = Array(repeating: false, count: bytes.count)
        }
        self.caseInsensitive = caseInsensitive
    }

    public var isEmpty: Bool { bytes.isEmpty }

    /// Hex digits with optional spaces. `??` is one wildcard byte.
    public static func hex(_ text: String) -> HexPattern? {
        let scalars = text.unicodeScalars.filter { !$0.properties.isWhitespace }
        guard !scalars.isEmpty, scalars.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        var mask: [Bool] = []
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let next = scalars.index(index, offsetBy: 2)
            let token = String(scalars[index..<next])
            if token.caseInsensitiveCompare("??") == .orderedSame {
                bytes.append(0)
                mask.append(true)
            } else if let value = UInt8(token, radix: 16) {
                bytes.append(value)
                mask.append(false)
            } else {
                return nil
            }
            index = next
        }
        return HexPattern(bytes: bytes, wildcard: mask, caseInsensitive: false)
    }

    public static func text(_ string: String, encoding: HexSearchTextEncoding, caseInsensitive: Bool) -> HexPattern? {
        guard let bytes = encoding.encode(string), !bytes.isEmpty else { return nil }
        return HexPattern(bytes: bytes, wildcard: nil, caseInsensitive: caseInsensitive)
    }
}

public enum HexSearchTextEncoding: String, Sendable, CaseIterable {
    case ascii
    case utf8
    case utf16LE
    case utf16BE
    case latin1

    public func encode(_ string: String) -> [UInt8]? {
        switch self {
        case .ascii:
            guard string.unicodeScalars.allSatisfy({ $0.value < 128 }) else { return nil }
            return Array(string.utf8)
        case .utf8:
            return Array(string.utf8)
        case .latin1:
            var out: [UInt8] = []
            out.reserveCapacity(string.unicodeScalars.count)
            for scalar in string.unicodeScalars {
                guard scalar.value <= 255 else { return nil }
                out.append(UInt8(scalar.value))
            }
            return out
        case .utf16LE, .utf16BE:
            var out: [UInt8] = []
            out.reserveCapacity(string.utf16.count * 2)
            for unit in string.utf16 {
                let low = UInt8(truncatingIfNeeded: unit)
                let high = UInt8(truncatingIfNeeded: unit >> 8)
                if self == .utf16LE {
                    out.append(low)
                    out.append(high)
                } else {
                    out.append(high)
                    out.append(low)
                }
            }
            return out
        }
    }
}

public enum HexSearch {
    public static let defaultChunkSize = 1_048_576
    public static let defaultLimit = 100_000

    /// Matches, stopping after `limit`. `capped` is true when the limit stopped the scan early.
    public static func scan(
        in source: any HexByteSource,
        pattern: HexPattern,
        from start: Int64 = 0,
        direction: HexSearchDirection = .forward,
        chunkSize: Int = defaultChunkSize,
        limit: Int = defaultLimit
    ) throws -> (matches: [Range<Int64>], capped: Bool) {
        var matches: [Range<Int64>] = []
        let capped = try scan(
            in: source,
            pattern: pattern,
            from: start,
            direction: direction,
            chunkSize: chunkSize,
            limit: limit
        ) { range in
            matches.append(range)
            return true
        }
        return (matches, capped)
    }

    /// Calls `onMatch` for each hit. Return false to stop. Throws ``CancellationError`` when the task is cancelled.
    @discardableResult
    public static func scan(
        in source: any HexByteSource,
        pattern: HexPattern,
        from start: Int64 = 0,
        direction: HexSearchDirection = .forward,
        chunkSize: Int = defaultChunkSize,
        limit: Int = defaultLimit,
        onMatch: (Range<Int64>) -> Bool
    ) throws -> Bool {
        guard !pattern.isEmpty, limit > 0 else { return false }
        let size = max(1, chunkSize)
        if direction == .backward {
            return try scanBackward(
                in: source, pattern: pattern, from: start, chunkSize: size, limit: limit, onMatch: onMatch
            )
        }
        return try scanForward(
            in: source, pattern: pattern, from: start, chunkSize: size, limit: limit, onMatch: onMatch
        )
    }

    public static func find(
        in source: any HexByteSource,
        pattern: HexPattern,
        from start: Int64 = 0,
        direction: HexSearchDirection = .forward,
        chunkSize: Int = defaultChunkSize,
        limit: Int = defaultLimit
    ) -> AsyncThrowingStream<Range<Int64>, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    try scan(
                        in: source,
                        pattern: pattern,
                        from: start,
                        direction: direction,
                        chunkSize: chunkSize,
                        limit: limit
                    ) { range in
                        continuation.yield(range)
                        return !Task.isCancelled
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func scanForward(
        in source: any HexByteSource,
        pattern: HexPattern,
        from start: Int64,
        chunkSize: Int,
        limit: Int,
        onMatch: (Range<Int64>) -> Bool
    ) throws -> Bool {
        let total = source.count
        let patternCount = pattern.bytes.count
        var window = min(max(0, start), total)
        var found = 0
        var buffer: [UInt8] = []
        while window < total && found < limit {
            try Task.checkCancellation()
            let overlap = patternCount > 0 ? patternCount - 1 : 0
            let readEnd = min(total, window + Int64(chunkSize) + Int64(overlap))
            let length = Int(readEnd - window)
            if buffer.count < length { buffer = [UInt8](repeating: 0, count: length) }
            let got = try buffer.withUnsafeMutableBytes { raw in
                try source.read(window..<readEnd, into: raw)
            }
            let startLimit = readEnd == total ? got : min(got, chunkSize)
            var stop = false
            findMatches(in: buffer, length: got, pattern: pattern, base: window, startLimit: startLimit) { range in
                found += 1
                if !onMatch(range) || found >= limit {
                    stop = true
                    return false
                }
                return true
            }
            if stop || found >= limit { return found >= limit }
            if readEnd == total { break }
            window += Int64(chunkSize)
        }
        return false
    }

    private static func scanBackward(
        in source: any HexByteSource,
        pattern: HexPattern,
        from start: Int64,
        chunkSize: Int,
        limit: Int,
        onMatch: (Range<Int64>) -> Bool
    ) throws -> Bool {
        let total = source.count
        let patternCount = pattern.bytes.count
        var windowEnd = min(max(0, start), total)
        var found = 0
        var buffer: [UInt8] = []
        while windowEnd > 0 && found < limit {
            try Task.checkCancellation()
            let windowStart = max(0, windowEnd - Int64(chunkSize))
            let readEnd = min(total, windowEnd - 1 + Int64(patternCount))
            let length = Int(max(0, readEnd - windowStart))
            if length == 0 { break }
            if buffer.count < length { buffer = [UInt8](repeating: 0, count: length) }
            let got = try buffer.withUnsafeMutableBytes { raw in
                try source.read(windowStart..<readEnd, into: raw)
            }
            let startLimit = Int(min(Int64(got), windowEnd - windowStart))
            var hits: [Range<Int64>] = []
            findMatches(in: buffer, length: got, pattern: pattern, base: windowStart, startLimit: startLimit) { range in
                hits.append(range)
                return true
            }
            for range in hits.reversed() {
                found += 1
                if !onMatch(range) || found >= limit { return found >= limit }
            }
            if windowStart == 0 { break }
            windowEnd = windowStart
        }
        return false
    }

    private static func findMatches(
        in buffer: [UInt8],
        length: Int,
        pattern: HexPattern,
        base: Int64,
        startLimit: Int,
        onMatch: (Range<Int64>) -> Bool
    ) {
        let count = pattern.bytes.count
        guard count > 0, length >= count, startLimit > 0 else { return }
        let lastStart = min(startLimit, length - count + 1)
        guard lastStart > 0 else { return }
        buffer.withUnsafeBytes { raw in
            guard let pointer = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var origin = 0
            while origin < lastStart {
                guard let index = nextMatch(pointer, length: length, pattern: pattern, from: origin, lastStart: lastStart) else {
                    return
                }
                let range = (base + Int64(index))..<(base + Int64(index + count))
                if !onMatch(range) { return }
                origin = index + 1
            }
        }
    }

    private static func nextMatch(
        _ pointer: UnsafePointer<UInt8>,
        length: Int,
        pattern: HexPattern,
        from origin: Int,
        lastStart: Int
    ) -> Int? {
        let bytes = pattern.bytes
        guard let anchor = anchorIndex(pattern) else {
            var index = origin
            while index < lastStart {
                if matches(pointer, at: index, pattern: pattern) { return index }
                index += 1
            }
            return nil
        }
        let needle = bytes[anchor]
        var scan = origin
        while scan < lastStart {
            let anchorAt = scan + anchor
            guard anchorAt < length else { return nil }
            let remaining = length - anchorAt
            guard remaining > 0 else { return nil }
            guard let found = findAnchor(pointer.advanced(by: anchorAt), remaining: remaining, needle: needle, caseInsensitive: pattern.caseInsensitive) else {
                return nil
            }
            let index = anchorAt + found - anchor
            if index >= lastStart { return nil }
            if index >= origin && matches(pointer, at: index, pattern: pattern) {
                return index
            }
            scan = max(index + 1, scan + 1)
        }
        return nil
    }

    private static func anchorIndex(_ pattern: HexPattern) -> Int? {
        var best: (index: Int, frequency: Int)?
        var counts: [UInt8: Int] = [:]
        for (index, byte) in pattern.bytes.enumerated() where !pattern.wildcard[index] {
            counts[byte, default: 0] += 1
        }
        for (index, byte) in pattern.bytes.enumerated() where !pattern.wildcard[index] {
            let frequency = counts[byte] ?? 1
            if best == nil || frequency < best!.frequency {
                best = (index, frequency)
            }
        }
        return best?.index
    }

    private static func findAnchor(
        _ pointer: UnsafePointer<UInt8>,
        remaining: Int,
        needle: UInt8,
        caseInsensitive: Bool
    ) -> Int? {
        let raw = UnsafeRawPointer(pointer)
        if caseInsensitive, let folded = asciiPartner(needle) {
            let first = memchr(pointer, Int32(needle), remaining).map { raw.distance(to: UnsafeRawPointer($0)) }
            let second = memchr(pointer, Int32(folded), remaining).map { raw.distance(to: UnsafeRawPointer($0)) }
            switch (first, second) {
            case let (a?, b?): return min(a, b)
            case let (a?, nil): return a
            case let (nil, b?): return b
            case (nil, nil): return nil
            }
        }
        guard let found = memchr(pointer, Int32(needle), remaining) else { return nil }
        return raw.distance(to: UnsafeRawPointer(found))
    }

    private static func matches(_ pointer: UnsafePointer<UInt8>, at index: Int, pattern: HexPattern) -> Bool {
        for (offset, expected) in pattern.bytes.enumerated() {
            if pattern.wildcard[offset] { continue }
            let actual = pointer[index + offset]
            if actual == expected { continue }
            if pattern.caseInsensitive, asciiFold(actual) == asciiFold(expected) { continue }
            return false
        }
        return true
    }

    private static func asciiFold(_ byte: UInt8) -> UInt8 {
        if byte >= 65 && byte <= 90 { return byte &+ 32 }
        return byte
    }

    private static func asciiPartner(_ byte: UInt8) -> UInt8? {
        if byte >= 65 && byte <= 90 { return byte &+ 32 }
        if byte >= 97 && byte <= 122 { return byte &- 32 }
        return nil
    }
}
