import Foundation
import Penumbra
import TestTreeSitterLanguages
import TreeSitterCSS
import TreeSitterTypeScript

public extension TreeSitterLanguage {
    /// JavaScript including JSX captures. Script tags in HTML inject this language as `"javascript"`.
    static var javaScript: TreeSitterLanguage {
        let highlightsQuery = QueryResources.combinedQuery(fromFilesAt: [
            QueryResources.url(named: "highlights", in: "JavaScript"),
            QueryResources.url(named: "highlights-jsx", in: "JavaScript")
        ])
        let injectionsQuery = QueryResources.query(named: "injections", in: "JavaScript")
        return TreeSitterLanguage(
            tree_sitter_javascript(),
            highlightsQuery: highlightsQuery,
            injectionsQuery: injectionsQuery,
            indentationScopes: .javaScript,
            lineCommentPrefix: "//", blockCommentDelimiters: .cStyle
        )
    }

    // JSON has no comment syntax — `lineCommentPrefix` stays `nil`.
    static var json: TreeSitterLanguage {
        TreeSitterLanguage(
            tree_sitter_json(),
            highlightsQuery: QueryResources.query(named: "highlights", in: "JSON"),
            indentationScopes: .json
        )
    }

    static var python: TreeSitterLanguage {
        TreeSitterLanguage(
            tree_sitter_python(),
            highlightsQuery: QueryResources.query(named: "highlights", in: "Python"),
            indentationScopes: .python,
            lineCommentPrefix: "#"
        )
    }

    static var yaml: TreeSitterLanguage {
        TreeSitterLanguage(
            tree_sitter_yaml(),
            highlightsQuery: QueryResources.query(named: "highlights", in: "YAML"),
            indentationScopes: .yaml,
            lineCommentPrefix: "#"
        )
    }

    /// HTML. Supply ``BundledLanguageProvider`` (or ``HTMLLanguageProvider``) so `<script>` / `<style>`
    /// inject JavaScript and CSS. HTML has no line-comment syntax (only `<!-- -->`), so
    /// `lineCommentPrefix` stays `nil` — ⌘/ is a no-op here, matching every other editor's HTML mode;
    /// ⌥⌘/ toggles `<!-- -->`.
    static var html: TreeSitterLanguage {
        TreeSitterLanguage(
            tree_sitter_html(),
            highlightsQuery: QueryResources.query(named: "highlights", in: "HTML"),
            injectionsQuery: QueryResources.query(named: "injections", in: "HTML"),
            indentationScopes: .html,
            blockCommentDelimiters: .html
        )
    }

    // CSS has no line-comment syntax (only `/* */`), so `lineCommentPrefix` stays `nil`; ⌥⌘/ toggles `/* */`.
    static var css: TreeSitterLanguage {
        TreeSitterLanguage(
            tree_sitter_css(),
            highlightsQuery: QueryResources.query(named: "highlights", in: "CSS"),
            indentationScopes: .css,
            blockCommentDelimiters: .cStyle
        )
    }

    /// TypeScript (not TSX). Highlights are JavaScript's query plus TypeScript-specific captures.
    static var typeScript: TreeSitterLanguage {
        let highlightsQuery = QueryResources.combinedQuery(fromFilesAt: [
            QueryResources.url(named: "highlights", in: "JavaScript"),
            QueryResources.url(named: "highlights", in: "TypeScript")
        ])
        return TreeSitterLanguage(
            tree_sitter_typescript(),
            highlightsQuery: highlightsQuery,
            indentationScopes: .javaScript,
            lineCommentPrefix: "//", blockCommentDelimiters: .cStyle
        )
    }

    /// Prepared language for a ``LanguageIdentifier`` string (`"javascript"`, `"python"`, …), from
    /// ``LanguageDefinitionRegistry/shared``: the bundled grammars (``BundledGrammars``) and any a host
    /// registered. Prefer ``BundledLanguages/language(forIdentifier:)``, which caches the result.
    static func bundled(forIdentifier identifier: String) -> TreeSitterLanguage? {
        BundledGrammars.install()
        return LanguageDefinitionRegistry.shared.grammar(forIdentifier: identifier)
    }
}

/// The grammars `PenumbraLanguages` ships, keyed by the identifier they highlight. Installed into
/// ``LanguageDefinitionRegistry/shared`` the first time any bundled lookup runs, without replacing a
/// grammar a host registered for the same identifier.
///
/// Identifiers that share a grammar list it twice (`xml` highlights as HTML). `bash`, `sh`, `zsh` and
/// `patch` are aliases of `shell` and `diff` (``LanguageDefinition/aliases``), so they need no entry.
enum BundledGrammars {
    private static let grammars: [(identifier: String, make: @Sendable () -> TreeSitterLanguage?)] = [
        ("javascript", { .javaScript }),
        ("typescript", { .typeScript }),
        ("json", { .json }),
        ("python", { .python }),
        ("yaml", { .yaml }),
        ("toml", { .toml }),
        ("sql", { .sql }),
        ("html", { .html }),
        ("xml", { .html }),
        ("css", { .css }),
        ("scss", { .css }),
        ("swift", { .swift }),
        ("java", { .java }),
        ("groovy", { .java }),
        ("kotlin", { .kotlin }),
        ("go", { .go }),
        ("shell", { .bash }),
        ("graphql", { .graphQL }),
        ("markdown", { .markdown }),
        // Not a file type: `Block/injections.scm` injects this into every `(inline)` node. Omitting it
        // silently disabled all inline highlighting (bold, italic, links, code spans) for hosts using
        // `BundledLanguageProvider`.
        ("markdown_inline", { .markdownInline }),
        ("http", { .http }),
        ("mermaid", { .mermaid }),
        ("rust", { .rust }),
        ("c", { .c }),
        ("cpp", { .cpp }),
        ("diff", { .diff })
    ]

    private static let installed: Void = {
        let registry = LanguageDefinitionRegistry.shared
        for (identifier, make) in grammars {
            registry.setGrammar(forIdentifier: identifier, replacingExisting: false, make)
        }
    }()

    /// Idempotent and thread-safe.
    static func install() {
        _ = installed
    }
}
