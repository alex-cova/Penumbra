import Foundation
import os

/// The set of ``LanguageDefinition``s the editor knows, with the lookups built from them.
///
/// ``shared`` starts with ``LanguageDefinition/builtIns``. A host registers its own languages once at
/// launch, before documents are opened: grammars are prepared and cached on first use
/// (`BundledLanguages`), so a grammar registered later does not replace one already served.
///
/// Thread-safe. Lookups read an immutable snapshot, so they are cheap enough for file opens and
/// Markdown highlighting; registration rebuilds the indexes (a few dozen entries).
public final class LanguageDefinitionRegistry: Sendable {
    public typealias Grammar = @Sendable () -> TreeSitterLanguage?

    /// The registry the editor consults.
    public static let shared = LanguageDefinitionRegistry(definitions: LanguageDefinition.builtIns)

    private struct Snapshot: Sendable {
        /// Registration order; a re-registered definition moves to the end.
        var definitions: [LanguageDefinition] = []
        var grammars: [String: Grammar] = [:]
        var byID: [String: LanguageDefinition] = [:]
        var aliasToID: [String: String] = [:]
        var idByExtension: [String: String] = [:]
        var idByFileName: [String: String] = [:]
        var fenceNameByTag: [String: String] = [:]

        mutating func reindex() {
            byID = [:]
            aliasToID = [:]
            idByExtension = [:]
            idByFileName = [:]
            fenceNameByTag = [:]
            for definition in definitions {
                byID[definition.id] = definition
                for alias in definition.aliases {
                    aliasToID[alias] = definition.id
                }
                for fileExtension in definition.fileExtensions {
                    idByExtension[fileExtension.lowercased()] = definition.id
                }
                for fileName in definition.fileNames {
                    idByFileName[fileName.lowercased()] = definition.id
                }
                for tag in definition.fenceAliases {
                    fenceNameByTag[tag.lowercased()] = definition.fenceName ?? definition.id
                }
            }
        }
    }

    private let state: OSAllocatedUnfairLock<Snapshot>

    public init(definitions: [LanguageDefinition] = []) {
        var snapshot = Snapshot()
        for definition in definitions {
            Self.insert(definition, into: &snapshot)
        }
        snapshot.reindex()
        state = OSAllocatedUnfairLock(initialState: snapshot)
    }

    // MARK: Registration

    /// Adds `definition`, replacing the one with the same ``LanguageDefinition/id``. Its grammar, when
    /// it has one, becomes the grammar of that identifier.
    public func register(_ definition: LanguageDefinition) {
        state.withLock { snapshot in
            Self.insert(definition, into: &snapshot)
            snapshot.reindex()
        }
    }

    /// Removes the definition and the grammar registered for `identifier`. A host rarely needs it;
    /// tests use it to leave the shared registry as they found it.
    public func unregister(identifier: String) {
        state.withLock { snapshot in
            snapshot.definitions.removeAll { $0.id == identifier }
            snapshot.grammars[identifier] = nil
            snapshot.reindex()
        }
    }

    /// Sets the grammar of `identifier`, which need not have a definition (`"markdown_inline"` is
    /// injected into Markdown and is not a file type). With `replacingExisting` false an earlier
    /// grammar is kept, which is how `PenumbraLanguages` installs its bundled grammars without
    /// overriding a host's.
    public func setGrammar(forIdentifier identifier: String, replacingExisting: Bool = true, _ grammar: @escaping Grammar) {
        state.withLock { snapshot in
            if replacingExisting || snapshot.grammars[identifier] == nil {
                snapshot.grammars[identifier] = grammar
            }
        }
    }

    private static func insert(_ definition: LanguageDefinition, into snapshot: inout Snapshot) {
        snapshot.definitions.removeAll { $0.id == definition.id }
        snapshot.definitions.append(definition)
        if let grammar = definition.grammar {
            snapshot.grammars[definition.id] = grammar
        }
    }

    // MARK: Lookups

    /// The definition whose ``LanguageDefinition/id`` or alias is `identifier`.
    public func definition(forIdentifier identifier: String) -> LanguageDefinition? {
        state.withLock { snapshot in
            if let definition = snapshot.byID[identifier] { return definition }
            return snapshot.aliasToID[identifier].flatMap { snapshot.byID[$0] }
        }
    }

    /// The identifier for a file extension (without the dot, any case), or nil.
    public func identifier(forFileExtension fileExtension: String) -> String? {
        let key = fileExtension.lowercased()
        return state.withLock { $0.idByExtension[key] }
    }

    /// The identifier for a full file name (any case), or nil.
    public func identifier(forFileName fileName: String) -> String? {
        let key = fileName.lowercased()
        return state.withLock { $0.idByFileName[key] }
    }

    /// What a Markdown fence tag (already lowercased) normalizes to, or nil when no definition claims it.
    public func fenceName(forTag tag: String) -> String? {
        state.withLock { $0.fenceNameByTag[tag] }
    }

    /// The prepared-on-demand grammar closure for `identifier`, trying its aliases when nothing is
    /// registered under the identifier itself. Prefer `BundledLanguages.language(forIdentifier:)`, which
    /// caches the prepared language.
    public func grammar(forIdentifier identifier: String) -> TreeSitterLanguage? {
        let make: Grammar? = state.withLock { snapshot in
            if let grammar = snapshot.grammars[identifier] { return grammar }
            return snapshot.aliasToID[identifier].flatMap { snapshot.grammars[$0] }
        }
        return make?()
    }

    /// Definitions a Set Syntax menu lists, ordered by display name (case-insensitive, then identifier).
    public var selectableDefinitions: [LanguageDefinition] {
        state.withLock { $0.definitions }
            .filter(\.isSelectable)
            .sorted {
                let order = $0.displayName.caseInsensitiveCompare($1.displayName)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
    }

    /// The configuration of every definition that has one, keyed by identifier.
    public var configurations: [String: LanguageConfiguration] {
        state.withLock { snapshot in
            var result: [String: LanguageConfiguration] = [:]
            for definition in snapshot.definitions {
                if let configuration = definition.configuration {
                    result[definition.id] = configuration
                }
            }
            return result
        }
    }
}
