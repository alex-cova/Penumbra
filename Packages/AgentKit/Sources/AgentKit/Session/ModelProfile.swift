import Foundation

/// How strictly `edit_file` and `apply_patch` match the file. Canonical matching (line endings,
/// trailing whitespace, Unicode punctuation) is on for every tier: a unique match is unambiguous.
/// An indentation shift is only for local models, which often mis-copy leading whitespace.
public struct EditTolerance: Sendable, Equatable {
    public var matchCanonically: Bool
    public var shiftIndentation: Bool

    public init(matchCanonically: Bool = true, shiftIndentation: Bool = false) {
        self.matchCanonically = matchCanonically
        self.shiftIndentation = shiftIndentation
    }

    public static let hosted = EditTolerance(matchCanonically: true, shiftIndentation: false)
    public static let local = EditTolerance(matchCanonically: true, shiftIndentation: true)
}

public enum ModelTier: String, Sendable, Equatable {
    case hosted
    case local
}

/// One place for what changes with the model: where it runs, how edits match, and which prompt
/// variant the host asked for. The tool list stays the host's choice until a `--toolset core`
/// comparison with 5 or more trials says otherwise (`preferredToolset` stays nil).
public struct ModelProfile: Sendable, Equatable {
    public var tier: ModelTier
    public var editTolerance: EditTolerance
    /// `nil` means keep the tool list the host already chose.
    public var preferredToolset: String?
    public var promptVariant: PromptVariant

    public enum PromptVariant: String, Sendable, Equatable {
        case standard
        case local
    }

    public init(tier: ModelTier, editTolerance: EditTolerance, preferredToolset: String? = nil, promptVariant: PromptVariant = .standard) {
        self.tier = tier
        self.editTolerance = editTolerance
        self.preferredToolset = preferredToolset
        self.promptVariant = promptVariant
    }

    /// `ollama` and `mlx` are local. Anything else is hosted. `model` is accepted so a host can
    /// override a single name later; the default does not special-case names.
    public static func choose(provider: String, model: String) -> ModelProfile {
        _ = model
        let localProviders: Set<String> = ["ollama", "mlx"]
        let tier: ModelTier = localProviders.contains(provider.lowercased()) ? .local : .hosted
        return ModelProfile(
            tier: tier,
            editTolerance: tier == .local ? .local : .hosted,
            preferredToolset: nil,
            promptVariant: .standard)
    }
}

/// Counts failed `edit_file` / `apply_patch` calls per path within one run, so the third failure
/// can point the model at `write_file`.
public actor EditFailureLog {
    private var counts: [String: Int] = [:]

    public init() {}

    public func reset() { counts.removeAll() }

    /// The failure count for `path` after recording this one.
    public func recordFailure(_ path: String) -> Int {
        counts[path, default: 0] += 1
        return counts[path]!
    }

    public func recordSuccess(_ path: String) { counts[path] = 0 }

    public static func hint(count: Int) -> String? {
        guard count >= 3 else { return nil }
        return " This file has failed to edit \(count) times in this run. Use write_file to replace the whole file instead of another edit."
    }
}
