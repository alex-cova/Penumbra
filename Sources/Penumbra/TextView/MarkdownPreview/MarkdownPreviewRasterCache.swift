@preconcurrency import AppKit
import Foundation

/// Content-keyed cache of the markdown preview's expensive per-block work: rendered mermaid
/// diagrams (and their errors), syntax-highlighted code fences and decoded local images.
///
/// Keys are the block's content, not its index, so a diagram survives edits elsewhere in the
/// document, moving to another block index, and re-parses of unchanged text. Bounded by entry
/// count and by decoded image bytes; least recently used entries go first. Thread-safe: raster
/// work reads and fills it off the main actor.
public final class MarkdownPreviewRasterCache: @unchecked Sendable {
    struct MermaidEntry {
        var image: CGImage?
        var naturalSize: CGSize?
        var errorMessage: String?
    }

    private enum Key: Hashable {
        case mermaid(source: String, context: MarkdownPreviewStyle.MermaidRenderingContext)
        case code(language: String?, source: String)
        case image(path: String, modified: Date?)
    }

    private enum Value {
        case mermaid(MermaidEntry)
        case code(NSAttributedString)
        case image(CGImage)

        var byteCost: Int {
            switch self {
            case .mermaid(let entry):
                return entry.image.map { $0.bytesPerRow * $0.height } ?? 0
            case .image(let image):
                return image.bytesPerRow * image.height
            case .code(let attributed):
                return attributed.length * 16
            }
        }
    }

    private struct Entry {
        var value: Value
        var lastUse: UInt64
    }

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    private var totalBytes = 0
    /// Highlighted code depends on the theme; entries are only valid for this one.
    private var codeTheme: AnyObject?

    public let maxEntries: Int
    public let maxBytes: Int

    public init(maxEntries: Int = 512, maxBytes: Int = 256 * 1024 * 1024) {
        self.maxEntries = max(1, maxEntries)
        self.maxBytes = max(1, maxBytes)
    }

    var count: Int {
        lock.withLock { entries.count }
    }

    public func removeAll() {
        lock.withLock {
            entries.removeAll()
            totalBytes = 0
            codeTheme = nil
        }
    }

    // MARK: - Mermaid

    func mermaid(source: String, context: MarkdownPreviewStyle.MermaidRenderingContext) -> MermaidEntry? {
        guard case .mermaid(let entry) = lookup(.mermaid(source: source, context: context)) else { return nil }
        return entry
    }

    func storeMermaid(_ entry: MermaidEntry, source: String, context: MarkdownPreviewStyle.MermaidRenderingContext) {
        store(.mermaid(entry), for: .mermaid(source: source, context: context))
    }

    // MARK: - Code

    func highlightedCode(language: String?, source: String, theme: Theme) -> NSAttributedString? {
        lock.lock()
        defer { lock.unlock() }
        guard codeTheme === theme else { return nil }
        guard case .code(let attributed) = lookupLocked(.code(language: language, source: source)) else { return nil }
        return attributed
    }

    func storeHighlightedCode(_ attributed: NSAttributedString, language: String?, source: String, theme: Theme) {
        lock.lock()
        defer { lock.unlock() }
        if codeTheme !== theme {
            for key in entries.keys {
                if case .code = key { removeLocked(key) }
            }
            codeTheme = theme
        }
        storeLocked(.code(attributed), for: .code(language: language, source: source))
    }

    // MARK: - Images

    func image(path: String, modified: Date?) -> CGImage? {
        guard case .image(let image) = lookup(.image(path: path, modified: modified)) else { return nil }
        return image
    }

    func storeImage(_ image: CGImage, path: String, modified: Date?) {
        store(.image(image), for: .image(path: path, modified: modified))
    }

    // MARK: - Storage

    private func lookup(_ key: Key) -> Value? {
        lock.withLock { lookupLocked(key) }
    }

    private func lookupLocked(_ key: Key) -> Value? {
        guard var entry = entries[key] else { return nil }
        clock += 1
        entry.lastUse = clock
        entries[key] = entry
        return entry.value
    }

    private func store(_ value: Value, for key: Key) {
        lock.withLock { storeLocked(value, for: key) }
    }

    private func storeLocked(_ value: Value, for key: Key) {
        removeLocked(key)
        clock += 1
        entries[key] = Entry(value: value, lastUse: clock)
        totalBytes += value.byteCost
        evictLocked(keeping: key)
    }

    private func removeLocked(_ key: Key) {
        if let old = entries.removeValue(forKey: key) {
            totalBytes -= old.value.byteCost
        }
    }

    /// Drops least recently used entries until both bounds hold, never the entry just stored.
    private func evictLocked(keeping kept: Key) {
        guard entries.count > maxEntries || totalBytes > maxBytes else { return }
        let byAge = entries.filter { $0.key != kept }.sorted { $0.value.lastUse < $1.value.lastUse }
        for (key, _) in byAge {
            guard entries.count > maxEntries || totalBytes > maxBytes else { break }
            removeLocked(key)
        }
    }
}

extension MarkdownPreviewStyle.MermaidRenderingContext: Hashable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.backgroundRGBA == rhs.backgroundRGBA
            && lhs.foregroundRGBA == rhs.foregroundRGBA
            && lhs.mermaidMaxDimension == rhs.mermaidMaxDimension
    }

    public func hash(into hasher: inout Hasher) {
        for component in [backgroundRGBA.red, backgroundRGBA.green, backgroundRGBA.blue, backgroundRGBA.alpha,
                          foregroundRGBA.red, foregroundRGBA.green, foregroundRGBA.blue, foregroundRGBA.alpha] {
            hasher.combine(component)
        }
        hasher.combine(mermaidMaxDimension)
    }
}
