import Foundation

/// One manually injected language fragment: highlight `utf16Range` with the named language.
///
/// There are two sources. A persistent `language=ID` comment in the host language's comment
/// syntax (on the line above a string literal, or on the same line before it) is discovered by
/// the highlighter itself (`.comment`). A temporary injection (`.temporary`) comes from the
/// host app's ``ManualInjectionProviding`` (the Inject-language action) and lives only in memory.
///
/// Ranges are UTF-16 code units over the whole document — the same units as `NSRange` in
/// `StringView.substring(in:)`. The layer converts them to its native byte ranges internally.
/// A range must already be the string *content* (quotes excluded); the layer additionally carves
/// host interpolation spans (`${...}`, `\(...)`, `{...}` in f-strings) out of the fragment.
///
/// Intelligence (completion, diagnostics) inside fragments is out of scope: fragments get colors
/// only.
public struct ManualLanguageInjection: Sendable, Hashable {
    /// Where this injection came from. Precedence is temporary over comment over automatic
    /// (`injections.scm`) when ranges overlap.
    public enum Source: Sendable, Hashable {
        case comment
        case temporary
    }

    /// UTF-16 range of the string content to highlight with the injected language.
    public let utf16Range: NSRange
    /// Language identifier as the user wrote it (`SQL`, `js`, …). Aliases are resolved through
    /// the existing `languageProvider`, so `FenceLanguageName` spellings work. Unknown identifiers
    /// are ignored, never errors.
    public let languageIdentifier: String
    public let source: Source

    public init(utf16Range: NSRange, languageIdentifier: String, source: Source) {
        self.utf16Range = utf16Range
        self.languageIdentifier = languageIdentifier
        self.source = source
    }
}

/// Provides temporary (Inject-language action) manual injections for one document.
///
/// Called during full parses and incremental re-parses, which run off the main thread, so
/// implementations must be thread-safe. The layer caches the last answer and shifts it across
/// edits itself; the provider is only re-asked on a full parse, so a stale answer between a
/// keystroke and the next parse is expected and harmless.
public protocol ManualInjectionProviding: AnyObject {
    func manualInjections() -> [ManualLanguageInjection]
    /// Called by the layer after it shifts its cached temporary ranges across an edit, so a store
    /// that answers `manualInjections()` from absolute ranges can stay current. The default is a
    /// no-op; without it a store goes stale after any edit that does not rebuild the mode.
    /// Always invoked off the main thread — implementations must be thread-safe.
    func manualInjectionsDidShift(_ injections: [ManualLanguageInjection])
}

public extension ManualInjectionProviding {
    func manualInjectionsDidShift(_ injections: [ManualLanguageInjection]) {}
}
