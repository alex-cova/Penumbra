import Foundation

/// How a file is opened by size (F25). Large-file behaviour used to be whatever each feature's own
/// cap happened to do; this makes it one decision with names the host can show.
///
/// Above ``degradeBytes`` a file opens as plain text: no tree-sitter highlighting, no folding (and
/// the host should skip indexing and language intelligence for it). Above ``readOnlyBytes`` it is
/// also read-only. "Enable anyway" is a reload with ``disabled``.
///
/// The defaults come from the open figures in `docs/EDITOR_PERFORMANCE_REPORT.md`: 100 MB opened in
/// about 250 ms, so the degraded tier starts well above anything that opens fine today, and the
/// read-only tier starts where open time and resident memory (500 MB: ~5 s, ~1.4 GB) stop being
/// something an editor should offer to take on silently.
public struct LargeFilePolicy: Sendable, Equatable {
    public enum Tier: Int, Sendable, Comparable {
        case normal
        case degraded
        case readOnly

        public static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// A capability a tier takes away, named for the banner.
    public enum Feature: String, Sendable, CaseIterable {
        case syntaxHighlighting
        case folding
        case intelligence
        case editing

        public var title: String {
            switch self {
            case .syntaxHighlighting: "Syntax highlighting"
            case .folding: "Code folding"
            case .intelligence: "Indexing and code intelligence"
            case .editing: "Editing"
            }
        }
    }

    public var degradeBytes: Int64
    public var readOnlyBytes: Int64

    public init(degradeBytes: Int64, readOnlyBytes: Int64) {
        self.degradeBytes = degradeBytes
        self.readOnlyBytes = max(readOnlyBytes, degradeBytes)
    }

    /// 50 MB degrades, 500 MB is read-only.
    public static let standard = LargeFilePolicy(degradeBytes: 50 * 1_048_576, readOnlyBytes: 500 * 1_048_576)
    /// Every file gets full service ("Enable anyway").
    public static let disabled = LargeFilePolicy(degradeBytes: .max, readOnlyBytes: .max)

    public func tier(forByteCount byteCount: Int64) -> Tier {
        if byteCount >= readOnlyBytes { return .readOnly }
        if byteCount >= degradeBytes { return .degraded }
        return .normal
    }

    /// What `tier` turns off. Empty for `.normal`.
    public static func disabledFeatures(for tier: Tier) -> [Feature] {
        switch tier {
        case .normal: []
        case .degraded: [.syntaxHighlighting, .folding, .intelligence]
        case .readOnly: [.syntaxHighlighting, .folding, .intelligence, .editing]
        }
    }

    /// The file's size on disk, or nil when it cannot be read (the file is then judged normal).
    public static func byteCount(of url: URL) -> Int64? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }
}

/// Why a document opened degraded, for the host's banner. Nil on a normal document.
public struct LargeFileNotice: Sendable, Equatable {
    public let tier: LargeFilePolicy.Tier
    public let byteCount: Int64
    public let disabledFeatures: [LargeFilePolicy.Feature]

    public init(tier: LargeFilePolicy.Tier, byteCount: Int64) {
        self.tier = tier
        self.byteCount = byteCount
        self.disabledFeatures = LargeFilePolicy.disabledFeatures(for: tier)
    }

    /// "Large file (120 MB): syntax highlighting, code folding and indexing and code intelligence are off."
    public var message: String {
        let size = ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
        let names = disabledFeatures.map { $0.title.lowercased() }
        let list: String
        switch names.count {
        case 0: list = ""
        case 1: list = names[0]
        default: list = names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
        let readOnly = tier == .readOnly ? " The file is read-only." : ""
        return "Large file (\(size)): \(list) are off.\(readOnly)"
    }
}
