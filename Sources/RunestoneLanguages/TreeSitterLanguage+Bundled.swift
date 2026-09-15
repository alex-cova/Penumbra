import Foundation
import Runestone
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
    /// GraphQL and Markdown stay in their own modules.
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
        case "html":
            return .html
        case "css", "scss":
            return .css
        case "swift":
            return .swift
        case "http":
            return .http
        case "mermaid":
            return .mermaid
        default:
            return nil
        }
    }
}
