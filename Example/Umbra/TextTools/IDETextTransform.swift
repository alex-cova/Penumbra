import Foundation

/// What a transform may need to know about where its text sits.
struct IDETextTransformContext: Sendable {
    /// One indent level of the editor (a tab, or the configured number of spaces).
    var indentUnit = "  "
    /// The whitespace the line holding the start of the selection begins with.
    var baseIndent = ""
}

/// One entry of the editor's Tools menu and of the command palette. `apply` is pure: `nil` means
/// the text cannot be converted (invalid JSON, not Base64) and nothing changes.
struct IDETextTransform: Sendable {
    /// Menu sections, in the order they appear.
    enum Group: CaseIterable, Sendable {
        case encoding, json, textCase, lines
    }

    let id: String
    let title: String
    let group: Group
    let apply: @Sendable (String, IDETextTransformContext) -> String?
}

enum IDETextTransforms {
    static let all: [IDETextTransform] = [
        .init(id: "base64.encode", title: "Encode Base64", group: .encoding) { text, _ in IDEBase64Text.encode(text) },
        .init(id: "base64.decode", title: "Decode Base64", group: .encoding) { text, _ in IDEBase64Text.decode(text) },
        .init(id: "url.encode", title: "URL Encode", group: .encoding) { text, _ in IDEURLText.encode(text) },
        .init(id: "url.decode", title: "URL Decode", group: .encoding) { text, _ in IDEURLText.decode(text) },
        .init(id: "html.encode", title: "Encode HTML Entities", group: .encoding) { text, _ in IDEHTMLText.encode(text) },
        .init(id: "html.decode", title: "Decode HTML Entities", group: .encoding) { text, _ in IDEHTMLText.decode(text) },
        .init(id: "hex.encode", title: "Hex Encode", group: .encoding) { text, _ in IDEHexText.encode(text) },
        .init(id: "hex.decode", title: "Hex Decode", group: .encoding) { text, _ in IDEHexText.decode(text) },
        .init(id: "string.escape", title: "Escape String", group: .encoding) { text, _ in IDEStringEscapeText.escape(text) },
        .init(id: "string.unescape", title: "Unescape String", group: .encoding) { text, _ in IDEStringEscapeText.unescape(text) },
        .init(id: "unicode.escape", title: "Unicode Escape", group: .encoding) { text, _ in IDEUnicodeEscapeText.escape(text) },
        .init(id: "unicode.unescape", title: "Unicode Unescape", group: .encoding) { text, _ in IDEUnicodeEscapeText.unescape(text) },
        .init(id: "json.format", title: "Format JSON", group: .json) { text, context in
            IDEJSONText.format(text, indentUnit: context.indentUnit, baseIndent: context.baseIndent)
        },
        .init(id: "json.minify", title: "Minify JSON", group: .json) { text, _ in IDEJSONText.minify(text) },
        .init(id: "case.upper", title: "UPPERCASE", group: .textCase) { text, _ in IDECaseText.uppercase(text) },
        .init(id: "case.lower", title: "lowercase", group: .textCase) { text, _ in IDECaseText.lowercase(text) },
        .init(id: "case.title", title: "Title Case", group: .textCase) { text, _ in IDECaseText.titleCase(text) },
        .init(id: "case.camel", title: "camelCase", group: .textCase) { text, _ in IDECaseText.convert(text, to: .camel) },
        .init(id: "case.pascal", title: "PascalCase", group: .textCase) { text, _ in IDECaseText.convert(text, to: .pascal) },
        .init(id: "case.snake", title: "snake_case", group: .textCase) { text, _ in IDECaseText.convert(text, to: .snake) },
        .init(id: "case.kebab", title: "kebab-case", group: .textCase) { text, _ in IDECaseText.convert(text, to: .kebab) },
        .init(id: "case.screaming", title: "SCREAMING_SNAKE_CASE", group: .textCase) { text, _ in
            IDECaseText.convert(text, to: .screamingSnake)
        },
        .init(id: "lines.sortAscending", title: "Sort Lines Ascending", group: .lines) { text, _ in IDELineText.sortAscending(text) },
        .init(id: "lines.sortDescending", title: "Sort Lines Descending", group: .lines) { text, _ in IDELineText.sortDescending(text) },
        .init(id: "lines.removeDuplicates", title: "Remove Duplicate Lines", group: .lines) { text, _ in IDELineText.removeDuplicates(text) },
        .init(id: "lines.reverse", title: "Reverse Lines", group: .lines) { text, _ in IDELineText.reverse(text) },
        .init(id: "lines.removeBlank", title: "Remove Blank Lines", group: .lines) { text, _ in IDELineText.removeBlankLines(text) },
        .init(id: "lines.trimTrailing", title: "Trim Trailing Whitespace", group: .lines) { text, _ in
            IDELineText.trimTrailingWhitespace(text)
        }
    ]

    static func transform(id: String) -> IDETextTransform? {
        all.first { $0.id == id }
    }
}
