import Foundation
import EditorIntelligence

/// An immutable, pre-processed snapshot of a project's files, built once (off the main thread)
/// and queried on every keystroke of Go to File.
///
/// Everything a query needs is precomputed into flat arrays: lowercased UTF-8 path bytes, where
/// each file name starts, its word starts (camel-hump anchors) and a 64-bit character-presence
/// mask. A query therefore never allocates per candidate; it rejects most files with one AND and
/// scores the survivors on raw bytes. Only the few rows that are displayed touch `String`.
///
/// Matching follows IntelliJ: the file *name* is matched by tier (exact > stem > prefix >
/// camel-hump > word-start > substring) and a path-only subsequence is the weakest fallback.
/// `dir/Name` restricts the directory; whitespace separates terms that must all match.
public final class PaletteFileIndex: Sendable {
    public struct Entry: Sendable {
        public let url: URL
        /// Path used for matching and the footer, relative to the project root when possible.
        public let relativePath: String
        /// Dimmed column after the name (e.g. the folder inside its module).
        public let location: String?
        /// Right-aligned column (e.g. `sxb-gateway.main`).
        public let module: String?
        public let icon: PaletteIcon

        public init(url: URL, relativePath: String, location: String?, module: String?, icon: PaletteIcon) {
            self.url = url
            self.relativePath = relativePath
            self.location = location
            self.module = module
            self.icon = icon
        }
    }

    public struct Hit: Sendable, Equatable {
        public let index: Int
        public let score: Int
    }

    public struct SearchResult: Sendable {
        public let hits: [Hit]
        /// Every entry that matched at the weakest tier, when the query is narrowable. Passing it
        /// back as `candidates` for a query that extends this one skips the rest of the index.
        public let candidates: [Int32]?
    }

    public let entries: [Entry]
    /// Every entry's URL, in index order (for callers that need a plain file list).
    public let urls: [URL]

    private let pathBytes: [UInt8]
    private let pathOffsets: [Int32]
    private let nameStarts: [Int32]
    private let wordStarts: [UInt64]
    private let masks: [UInt64]
    private let indexByPath: [String: Int32]

    public var count: Int { entries.count }

    public init(entries: [Entry]) {
        self.entries = entries
        self.urls = entries.map(\.url)
        var bytes: [UInt8] = []
        var offsets: [Int32] = []
        var nameStarts: [Int32] = []
        var wordStarts: [UInt64] = []
        var masks: [UInt64] = []
        var indexByPath: [String: Int32] = [:]
        offsets.reserveCapacity(entries.count + 1)
        nameStarts.reserveCapacity(entries.count)
        wordStarts.reserveCapacity(entries.count)
        masks.reserveCapacity(entries.count)
        indexByPath.reserveCapacity(entries.count)

        for (index, entry) in entries.enumerated() {
            let start = bytes.count
            offsets.append(Int32(start))
            var nameStart = start
            var mask: UInt64 = 0
            var previous: UInt8 = 0
            var starts: UInt64 = 0
            var position = 0
            for byte in entry.relativePath.utf8 {
                if byte == UInt8(ascii: "/") {
                    nameStart = bytes.count + 1
                    position = 0
                    previous = 0
                    starts = 0
                } else {
                    if position < 64, Self.isWordStart(byte, previous: previous, isFirst: position == 0) {
                        starts |= 1 << UInt64(position)
                    }
                    position += 1
                    previous = byte
                }
                bytes.append(Self.lower(byte))
                mask |= Self.maskBit(for: byte)
            }
            nameStarts.append(Int32(nameStart))
            wordStarts.append(starts)
            masks.append(mask)
            indexByPath[entry.url.path] = Int32(index)
        }
        offsets.append(Int32(bytes.count))
        self.pathBytes = bytes
        self.pathOffsets = offsets
        self.nameStarts = nameStarts
        self.wordStarts = wordStarts
        self.masks = masks
        self.indexByPath = indexByPath
    }

    public func entry(at index: Int) -> Entry { entries[index] }

    /// The entry for `url`, or `nil` when it isn't indexed.
    public func entry(for url: URL) -> Entry? { entry(forPath: url.path) }

    public func entry(forPath path: String) -> Entry? {
        indexByPath[path].map { entries[Int($0)] }
    }

    /// Whether any entry lives under the directory `relativePath` (relative to the index root).
    /// A linear scan — meant for rare checks such as "was a whole folder deleted?".
    public func hasEntries(underRelativeDirectory relativePath: String) -> Bool {
        let prefix = relativePath.hasSuffix("/") ? relativePath : relativePath + "/"
        return entries.contains { $0.relativePath.hasPrefix(prefix) }
    }

    // MARK: - Search

    /// - Parameters:
    ///   - boosts: Recently used / open files, most recent first. They lead an empty query and win ties.
    ///   - candidates: A previous ``SearchResult/candidates`` for a query this one extends.
    public func search(_ rawQuery: String, limit: Int, boosts: [URL] = [], among candidates: [Int32]? = nil) -> SearchResult {
        let terms = Self.parse(rawQuery)
        let boostBonus = boostBonuses(for: boosts)
        guard !terms.isEmpty else {
            return SearchResult(hits: emptyQueryHits(limit: limit, boosts: boosts), candidates: nil)
        }
        var queryMask: UInt64 = 0
        for term in terms {
            for byte in term.dir + term.name { queryMask |= Self.maskBit(for: byte) }
        }
        let narrowable = terms.count == 1 && terms[0].dir.isEmpty
        var top = TopK(capacity: max(limit, 1))
        var matched: [Int32] = []
        let total = candidates?.count ?? entries.count

        pathBytes.withUnsafeBufferPointer { buffer in
            for k in 0..<total {
                if k & 1023 == 0, Task.isCancelled { return }
                let index = candidates?[k] ?? Int32(k)
                let i = Int(index)
                if queryMask & ~masks[i] != 0 { continue }
                guard var score = evaluate(terms[0], at: i, in: buffer) else { continue }
                var ok = true
                for term in terms.dropFirst() {
                    guard let extra = evaluate(term, at: i, in: buffer) else { ok = false; break }
                    score += extra / 4
                }
                guard ok else { continue }
                if narrowable { matched.append(index) }
                score -= Int(pathOffsets[i + 1] - pathOffsets[i]) / 8
                if let bonus = boostBonus[index] { score += bonus }
                top.insert(score: score, index: index)
            }
        }
        let hits = top.entries.map { Hit(index: Int($0.index), score: $0.score) }
        return SearchResult(hits: hits, candidates: narrowable && !Task.isCancelled ? matched : nil)
    }

    /// Character offsets in the file name to render bold for `query`. Empty when the file only
    /// matched through its directory.
    public func highlightOffsets(forEntryAt index: Int, query: String) -> [Int] {
        guard let term = Self.parse(query).first, !term.nameOriginal.isEmpty else { return [] }
        let name = entries[index].url.lastPathComponent
        if let match = CompletionMatcher.match(term.nameOriginal, in: name) {
            return match.matchedOffsets
        }
        let lowerName = Array(name.lowercased().utf16)
        let lowerQuery = Array(term.nameOriginal.lowercased().utf16)
        guard !lowerQuery.isEmpty, lowerQuery.count <= lowerName.count else { return [] }
        for start in 0...(lowerName.count - lowerQuery.count)
        where Array(lowerName[start..<(start + lowerQuery.count)]) == lowerQuery {
            return Array(start..<(start + lowerQuery.count))
        }
        return []
    }

    // MARK: - Scoring

    private func evaluate(_ term: Term, at i: Int, in buffer: UnsafeBufferPointer<UInt8>) -> Int? {
        let pathStart = Int(pathOffsets[i])
        let pathEnd = Int(pathOffsets[i + 1])
        let nameStart = Int(nameStarts[i])
        if !term.dir.isEmpty,
           !Self.isSubsequence(term.dir, in: buffer, from: pathStart, to: nameStart) {
            return nil
        }
        let query = term.name
        if query.isEmpty { return 1_000 }
        let nameLength = pathEnd - nameStart
        let lengthPenalty = min(nameLength, 100)
        let dirBonus = term.dir.isEmpty ? 0 : 200

        if query.count <= nameLength {
            // Prefix (and its exact / stem specialisations).
            var isPrefix = true
            for j in 0..<query.count where buffer[nameStart + j] != query[j] {
                isPrefix = false
                break
            }
            if isPrefix {
                if query.count == nameLength { return 10_000 + dirBonus }
                if buffer[nameStart + query.count] == UInt8(ascii: ".") {
                    var extraDot = false
                    for j in (query.count + 1)..<nameLength where buffer[nameStart + j] == UInt8(ascii: ".") {
                        extraDot = true
                        break
                    }
                    if !extraDot { return 9_000 - lengthPenalty + dirBonus }
                }
                return 5_000 - lengthPenalty + dirBonus
            }
            let starts = wordStarts[i]
            if let anchoredAtStart = Self.humpMatch(query, in: buffer, nameStart: nameStart, nameLength: nameLength, starts: starts) {
                return (anchoredAtStart ? 3_000 : 1_500) - lengthPenalty + dirBonus
            }
            if Self.containsSubstring(query, in: buffer, from: nameStart, to: pathEnd) {
                return 700 - lengthPenalty + dirBonus
            }
        }
        if term.dir.isEmpty, Self.isSubsequence(query, in: buffer, from: pathStart, to: pathEnd) {
            return 100
        }
        return nil
    }

    /// `true` when anchored at the name's first character, `false` when anchored at a later word
    /// start, `nil` when there is no camel-hump match.
    private static func humpMatch(
        _ query: [UInt8],
        in buffer: UnsafeBufferPointer<UInt8>,
        nameStart: Int,
        nameLength: Int,
        starts: UInt64
    ) -> Bool? {
        func isStart(_ position: Int) -> Bool { position < 64 && starts & (1 << UInt64(position)) != 0 }

        func match(_ queryIndex: Int, previousEnd: Int) -> Bool {
            if queryIndex == query.count { return true }
            let next = previousEnd + 1
            if next < nameLength, buffer[nameStart + next] == query[queryIndex], match(queryIndex + 1, previousEnd: next) {
                return true
            }
            var position = next
            while position < nameLength {
                if isStart(position), buffer[nameStart + position] == query[queryIndex],
                   position != next, match(queryIndex + 1, previousEnd: position) {
                    return true
                }
                position += 1
            }
            return false
        }

        if buffer[nameStart] == query[0], match(1, previousEnd: 0) { return true }
        var position = 1
        while position < min(nameLength, 64) {
            if isStart(position), buffer[nameStart + position] == query[0], match(1, previousEnd: position) {
                return false
            }
            position += 1
        }
        return nil
    }

    private static func containsSubstring(_ query: [UInt8], in buffer: UnsafeBufferPointer<UInt8>, from: Int, to: Int) -> Bool {
        let last = to - query.count
        guard last >= from else { return false }
        var start = from
        while start <= last {
            if buffer[start] == query[0] {
                var j = 1
                while j < query.count, buffer[start + j] == query[j] { j += 1 }
                if j == query.count { return true }
            }
            start += 1
        }
        return false
    }

    private static func isSubsequence(_ query: [UInt8], in buffer: UnsafeBufferPointer<UInt8>, from: Int, to: Int) -> Bool {
        var q = 0
        var position = from
        while position < to, q < query.count {
            if buffer[position] == query[q] { q += 1 }
            position += 1
        }
        return q == query.count
    }

    // MARK: - Empty query & boosts

    private func boostBonuses(for boosts: [URL]) -> [Int32: Int] {
        var result: [Int32: Int] = [:]
        for (rank, url) in boosts.enumerated() {
            if let index = indexByPath[url.path] {
                result[index] = 1_500 + max(0, 50 - rank)
            }
        }
        return result
    }

    private func emptyQueryHits(limit: Int, boosts: [URL]) -> [Hit] {
        var hits: [Hit] = []
        var seen = Set<Int32>()
        for url in boosts {
            guard hits.count < limit, let index = indexByPath[url.path], seen.insert(index).inserted else { continue }
            hits.append(Hit(index: Int(index), score: limit - hits.count))
        }
        var next = 0
        while hits.count < limit, next < entries.count {
            if seen.insert(Int32(next)).inserted {
                hits.append(Hit(index: next, score: limit - hits.count))
            }
            next += 1
        }
        return hits
    }

    // MARK: - Query parsing

    struct Term {
        /// Lowercased directory bytes (`api/` in `api/ApiKey`), possibly empty.
        let dir: [UInt8]
        /// Lowercased file-name bytes.
        let name: [UInt8]
        let nameOriginal: String
    }

    static func parse(_ rawQuery: String) -> [Term] {
        rawQuery.split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { piece in
            let text = String(piece)
            guard !text.isEmpty else { return nil }
            var dirPart = ""
            var namePart = text
            if let slash = text.lastIndex(of: "/") {
                dirPart = String(text[..<slash]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                namePart = String(text[text.index(after: slash)...])
            }
            return Term(
                dir: Array(dirPart.utf8).map(lower),
                name: Array(namePart.utf8).map(lower),
                nameOriginal: namePart
            )
        }
    }

    // MARK: - Byte helpers

    @inline(__always)
    private static func lower(_ byte: UInt8) -> UInt8 {
        (byte >= 65 && byte <= 90) ? byte | 0x20 : byte
    }

    private static func isWordStart(_ byte: UInt8, previous: UInt8, isFirst: Bool) -> Bool {
        if isFirst { return true }
        if isSeparator(previous) { return !isSeparator(byte) }
        let isUpper = byte >= 65 && byte <= 90
        let previousIsUpper = previous >= 65 && previous <= 90
        return isUpper && !previousIsUpper
    }

    private static func isSeparator(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-") || byte == UInt8(ascii: " ")
    }

    private static func maskBit(for byte: UInt8) -> UInt64 {
        let b = lower(byte)
        switch b {
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return 1 << UInt64(b - UInt8(ascii: "a"))
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return 1 << UInt64(26 + b - UInt8(ascii: "0"))
        case UInt8(ascii: "."): return 1 << 36
        case UInt8(ascii: "_"): return 1 << 37
        case UInt8(ascii: "-"): return 1 << 38
        case UInt8(ascii: "/"): return 0
        case 0..<128: return 1 << 39
        default: return 1 << 40
        }
    }

    // MARK: - Top-k

    private struct TopK {
        struct Item { let score: Int; let index: Int32 }
        let capacity: Int
        var entries: [Item] = []

        init(capacity: Int) {
            self.capacity = capacity
            entries.reserveCapacity(capacity + 1)
        }

        mutating func insert(score: Int, index: Int32) {
            if entries.count == capacity, let worst = entries.last, score <= worst.score { return }
            var position = entries.count
            while position > 0, entries[position - 1].score < score { position -= 1 }
            entries.insert(Item(score: score, index: index), at: position)
            if entries.count > capacity { entries.removeLast() }
        }
    }
}
