import Foundation

/// Builds a fully prepared ``TextViewState`` off the main thread. Callers must apply on the main queue.
///
/// Pair this with ``TreeSitterLanguageCache`` to avoid re-preparing (and re-compiling highlight
/// queries for) the same ``TreeSitterLanguage`` on every call to ``makeState(text:theme:language:languageProvider:parsePolicy:)``.
public enum PenumbraStateBuilder {
    /// Carries a non-Sendable ``TextViewState`` across queues after background preparation.
    public final class PreparedState: @unchecked Sendable {
        public let state: TextViewState
        public init(_ state: TextViewState) { self.state = state }
    }

    /// Weak reference box for crossing isolation boundaries with AppKit views.
    ///
    /// `@unchecked Sendable` here relies on `weak var`'s own thread safety: ARC's weak-reference
    /// side table is internally locked, so concurrent reads of `value` (including a concurrent
    /// read racing the referenced object's deallocation) are safe without an explicit lock of our
    /// own — unlike a plain `var T?`, which would need one. This box only ever wraps a single
    /// weak reference; a type with additional mutable state would need real synchronization.
    public final class WeakBox<T: AnyObject>: @unchecked Sendable {
        public weak var value: T?
        public init(_ value: T?) { self.value = value }
    }

    /// Holds a non-Sendable value for one-shot main-queue delivery after background work.
    public final class UncheckedBox<T>: @unchecked Sendable {
        public let value: T
        public init(_ value: T) { self.value = value }
    }

    /// Thread-safe generation counter for cancelling stale background prepares.
    public final class GenerationGate: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        public init() {}

        public var current: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        @discardableResult
        public func bump() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value &+= 1
            return value
        }

        public func matches(_ expected: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return value == expected
        }
    }

    public static func makeState(
        text: String,
        theme: Theme = DefaultTheme(),
        language: TreeSitterLanguage? = nil,
        languageProvider: TreeSitterLanguageProvider? = nil,
        parsePolicy: SyntaxParsePolicy = .viewport
    ) -> PreparedState {
        let state: TextViewState
        if let language {
            state = TextViewState(
                text: text,
                theme: theme,
                language: language,
                languageProvider: languageProvider,
                parsePolicy: parsePolicy
            )
        } else {
            state = TextViewState(text: text, theme: theme)
        }
        return PreparedState(state)
    }

    /// Loads a document from disk via ``TextViewState/load(contentsOf:theme:language:languageProvider:parsePolicy:encoding:io:progress:)``.
    ///
    /// Defaults to ``DocumentLoadIO/memoryMapped`` ingest and ``SyntaxParsePolicy/viewport`` parse
    /// so a host can open a large file without `String(contentsOf:)` and without a full-document tree.
    public static func load(
        contentsOf url: URL,
        theme: Theme = DefaultTheme(),
        language: TreeSitterLanguage? = nil,
        languageProvider: TreeSitterLanguageProvider? = nil,
        parsePolicy: SyntaxParsePolicy = .viewport,
        encoding: String.Encoding = .utf8,
        io: DocumentLoadIO = .memoryMapped,
        progress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> PreparedState {
        let state = try await TextViewState.load(
            contentsOf: url,
            theme: theme,
            language: language,
            languageProvider: languageProvider,
            parsePolicy: parsePolicy,
            encoding: encoding,
            io: io,
            progress: progress
        )
        return PreparedState(state)
    }

    /// Prepares state on a background queue, then invokes `apply` on the main queue when `isCurrent` is true.
    ///
    /// Defaults to ``SyntaxParsePolicy/viewport`` so the background hop only rebuilds the line
    /// index; the tree-sitter parse runs after ``TextView/setState(_:addUndoAction:)`` and is
    /// limited to the visible window on large files.
    public static func prepareAndApply(
        text: String,
        theme: Theme,
        language: TreeSitterLanguage?,
        languageProvider: TreeSitterLanguageProvider? = nil,
        parsePolicy: SyntaxParsePolicy = .viewport,
        generation: Int,
        isCurrent: @escaping (Int) -> Bool,
        apply: @escaping (TextViewState) -> Void
    ) {
        let isCurrentBox = UncheckedBox(isCurrent)
        let applyBox = UncheckedBox(apply)
        let themeBox = UncheckedBox(theme)
        let languageBox = UncheckedBox(language)
        let languageProviderBox = UncheckedBox(languageProvider)
        DispatchQueue.global(qos: .userInitiated).async {
            let prepared = makeState(
                text: text,
                theme: themeBox.value,
                language: languageBox.value,
                languageProvider: languageProviderBox.value,
                parsePolicy: parsePolicy
            )
            DispatchQueue.main.async {
                guard isCurrentBox.value(generation) else { return }
                applyBox.value(prepared.state)
            }
        }
    }
}
