import Foundation

/// Detects a plain-text language identifier from a file's name or extension — the piece needed to
/// populate ``WorkbenchDocument/languageIdentifier`` when opening a file, which nothing in
/// Penumbra does automatically today.
///
/// Identifiers are plain lowercase strings (`"swift"`, `"json"`, `"markdown"`, …) rather than an
/// enum: Penumbra doesn't ship a language enum, and a `String` lets a consumer freely add
/// languages. The table behind this is ``LanguageDefinitionRegistry/shared``: the bundled languages
/// (``LanguageDefinition/builtIns``) plus whatever a host registers. Where Penumbra ships a language
/// package for one of these identifiers, the identifier lines up with its natural name (e.g.
/// `"graphql"`, `"markdown"`); mapping an identifier to a `TreeSitterLanguage` is
/// ``LanguageDefinitionRegistry/grammar(forIdentifier:)`` (or `BundledLanguages` in `PenumbraLanguages`).
///
/// Deliberate deviation from a plain extension→language switch: unrecognized extensions return
/// `nil` rather than collapsing to `"plain"`, so a caller can distinguish "this file is explicitly
/// plain text" from "this extension isn't in the table, you decide the fallback."
public enum LanguageIdentifier {
    /// Checks file names that `URL.pathExtension` can't see (`.zshrc`, `.bashrc`, … → `"shell"`)
    /// first, then falls back to ``identifier(forFileExtension:)``.
    public static func identifier(for url: URL) -> String? {
        let registry = LanguageDefinitionRegistry.shared
        if let identifier = registry.identifier(forFileName: url.lastPathComponent) {
            return identifier
        }
        return registry.identifier(forFileExtension: url.pathExtension)
    }

    public static func identifier(forFileExtension fileExtension: String) -> String? {
        LanguageDefinitionRegistry.shared.identifier(forFileExtension: fileExtension)
    }
}
