import Foundation

/// Parsed blocks of each prose chunk from the previous parse, so re-parsing after an edit only
/// runs Foundation's markdown parser over the chunks whose text changed.
///
/// Prose is split into chunks before every ATX heading (`#` … `######` at column 0) that follows
/// a blank line: in CommonMark such a line always starts a new block and can't continue a list,
/// quote or paragraph above it, so parsing the chunks separately yields the same blocks as
/// parsing the whole. Fences are already split out by ``MermaidFenceExtractor``, and link
/// reference definitions are appended to every chunk, as they are to every prose segment.
/// Holds only the chunks of the most recent parse. Thread-safe.
public final class MarkdownPreviewParseCache: @unchecked Sendable {
    private struct Key: Hashable {
        var prose: String
        var linkDefinitions: String
    }

    private let lock = NSLock()
    private var entries: [Key: [MarkdownPreviewBlock]] = [:]
    private var nextEntries: [Key: [MarkdownPreviewBlock]] = [:]
    /// Chunks parsed (not found in the cache) by the last parse. Tests and benchmarks read it.
    private(set) var lastParsedChunkCount = 0

    public init() {}

    func begin() {
        lock.withLock {
            nextEntries.removeAll(keepingCapacity: true)
            lastParsedChunkCount = 0
        }
    }

    /// Blocks of one chunk, each with its `contentHash` computed.
    func blocks(forChunk prose: String, linkDefinitions: String) -> [MarkdownPreviewBlock] {
        let key = Key(prose: prose, linkDefinitions: linkDefinitions)
        if let cached = lock.withLock({ nextEntries[key] ?? entries[key] }) {
            lock.withLock { nextEntries[key] = cached }
            return cached
        }
        var blocks = MarkdownPreviewIntentWalker.blocks(in: prose, linkDefinitions: linkDefinitions)
        for index in blocks.indices {
            blocks[index].contentHash = blocks[index].kind.hashValue
        }
        lock.withLock {
            nextEntries[key] = blocks
            lastParsedChunkCount += 1
        }
        return blocks
    }

    func end() {
        lock.withLock {
            swap(&entries, &nextEntries)
            nextEntries.removeAll(keepingCapacity: true)
        }
    }

    private static let chunkBoundary = try! NSRegularExpression(
        pattern: #"\n[ \t]*\n(?=#{1,6}(?:[ \t]|\n|$))"#,
        options: [.anchorsMatchLines]
    )

    /// HTML blocks that, unlike the rest of CommonMark's blocks, run past blank lines — a `#`
    /// line inside one is not a heading, so prose containing any of them isn't split.
    private static let blankLineSpanningOpeners: [[UInt8]] = ["!--", "pre", "script", "style", "textarea", "?", "![cdata["]
        .map { Array($0.utf8) }

    /// One pass over the bytes: after each `<`, compares the following bytes (ASCII-lowercased)
    /// with the openers.
    static func containsBlankLineSpanningHTML(_ prose: String) -> Bool {
        var prose = prose
        return prose.withUTF8 { bytes in
            var index = 0
            while index < bytes.count {
                defer { index += 1 }
                guard bytes[index] == UInt8(ascii: "<") else { continue }
                for opener in blankLineSpanningOpeners where index + opener.count < bytes.count {
                    var matches = true
                    for offset in 0 ..< opener.count {
                        var byte = bytes[index + 1 + offset]
                        if byte >= UInt8(ascii: "A"), byte <= UInt8(ascii: "Z") { byte += 32 }
                        if byte != opener[offset] {
                            matches = false
                            break
                        }
                    }
                    if matches { return true }
                }
            }
            return false
        }
    }

    /// Splits `prose` before each ATX heading that follows a blank line. The pieces concatenate
    /// back to `prose`.
    static func chunks(of prose: String) -> [String] {
        if containsBlankLineSpanningHTML(prose) {
            return [prose]
        }
        let ns = prose as NSString
        var result: [String] = []
        var cursor = 0
        for match in chunkBoundary.matches(in: prose, range: NSRange(location: 0, length: ns.length)) {
            let end = match.range.location + match.range.length
            result.append(ns.substring(with: NSRange(location: cursor, length: end - cursor)))
            cursor = end
        }
        if cursor < ns.length || result.isEmpty {
            result.append(ns.substring(from: cursor))
        }
        return result
    }
}
