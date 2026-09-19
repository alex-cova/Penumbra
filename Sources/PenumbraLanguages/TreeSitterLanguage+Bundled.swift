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
            lineCommentPrefix: "//"
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
    /// `lineCommentPrefix` stays `nil` — ⌘/ is a no-op here, matching every other editor's HTML mode.
    static var html: TreeSitterLanguage {
        TreeSitterLanguage(
            tree_sitter_html(),
            highlightsQuery: QueryResources.query(named: "highlights", in: "HTML"),
            injectionsQuery: QueryResources.query(named: "injections", in: "HTML"),
            indentationScopes: .html
        )
    }

    // CSS has no line-comment syntax (only `/* */`), so `lineCommentPrefix` stays `nil`.
    static var css: TreeSitterLanguage {
        TreeSitterLanguage(
            tree_sitter_css(),
            highlightsQuery: QueryResources.query(named: "highlights", in: "CSS"),
            indentationScopes: .css
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
            lineCommentPrefix: "//"
        )
    }

    /// Prepared language for a ``LanguageIdentifier`` string (`"javascript"`, `"python"`, …).
    static func bundled(forIdentifier identifier: String) -> TreeSitterLanguage? {
        switch identifier {
        case "javascript":
            return .javaScript
        case "typescript":
            return .typeScript
        case "json":
            return .json
        case "python":
            return .python
        case "yaml":
            return .yaml
        case "toml":
            return .toml
        case "sql":
            return .sql
        case "html", "xml":
            return .html
        case "css", "scss":
            return .css
        case "swift":
            return .swift
        case "java", "groovy":
            return .java
        case "kotlin":
            return .kotlin
        case "go":
            return .go
        case "shell", "bash", "sh", "zsh":
            return .bash
        case "graphql":
            return .graphQL
        case "markdown":
            return .markdown
        // Not a file type: `Block/injections.scm` injects this into every `(inline)` node. This switch
        // is `BundledLanguageProvider`'s only resolution path, and omitting it silently disabled all
        // inline highlighting (bold, italic, links, code spans) for hosts using that provider.
        case "markdown_inline":
            return .markdownInline
        case "http":
            return .http
        case "mermaid":
            return .mermaid
        case "rust":
            return .rust
        case "c":
            return .c
        case "cpp":
            return .cpp
        case "diff", "patch":
            return .diff
        case "plain":
            return nil
        default:
            return nil
        }
    }
}
