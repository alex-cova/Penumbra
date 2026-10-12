import EditorIntelligence
import Foundation
import LanguageSyntax

/// One SwiftUI preview in a file: a `#Preview` block or a `PreviewProvider` type.
///
/// Everything is syntactic and addressed by UTF-8 byte ranges of the buffer it was extracted from,
/// like the rest of the Swift model. Nothing here knows how a preview is built or shown; the thunk
/// generator and the host consume these values.
public struct SwiftPreviewBlock: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// `#Preview { … }`.
        case macro
        /// `struct Foo_Previews: PreviewProvider { static var previews … }`; the associated value is the type's name.
        case provider(typeName: String)
    }

    /// A `@Previewable` declaration at the start of a `#Preview` body.
    public struct Previewable: Sendable, Equatable {
        public var name: String
        /// The declaration as written, `@Previewable` included.
        public var text: String
        /// The declaration without `@Previewable`: `@State var count = 0`.
        public var declarationText: String
        public var bytes: Range<Int>
    }

    public var kind: Kind
    /// The first unlabeled string argument of `#Preview("Dark")`, between its quotes, as written.
    public var title: String?
    /// Position among the blocks of the file, in source order. A selector for the host.
    public var index: Int
    /// The trait arguments as written (`.fixedLayout(width: 1, height: 2), .landscapeLeft`); nil when there are none.
    public var traits: String?
    /// The whole `#Preview(...) { ... }` expression, or the whole provider type.
    public var fullBytes: Range<Int>
    /// Between the braces of the body: the preview closure, or the `previews` getter.
    public var bodyBytes: Range<Int>
    /// `bodyBytes` after the leading `@Previewable` declarations: the view the preview shows.
    public var contentBytes: Range<Int>
    public var previewables: [Previewable]
    /// 1-based line of `#Preview` or of the provider's name.
    public var line: Int

    /// The label a canvas shows for the block.
    public var displayName: String {
        if let title, !title.isEmpty { return title }
        switch kind {
        case .macro: return "Preview \(index + 1)"
        case .provider(let name): return name
        }
    }
}

public enum SwiftPreviewExtractor {
    public static func extract(from source: String) -> [SwiftPreviewBlock] {
        guard source.contains("Preview"), let parsed = SwiftAnalysis.parse(source) else { return [] }
        return extract(from: parsed)
    }

    /// Previews in source order. The macro blocks and the provider types are merged by position.
    public static func extract(from parsed: SwiftParsed) -> [SwiftPreviewBlock] {
        var blocks = macroBlocks(in: parsed) + providerBlocks(in: parsed)
        blocks.sort { $0.fullBytes.lowerBound < $1.fullBytes.lowerBound }
        for position in blocks.indices { blocks[position].index = position }
        return blocks
    }

    // MARK: - #Preview

    private static func macroBlocks(in parsed: SwiftParsed) -> [SwiftPreviewBlock] {
        var blocks: [SwiftPreviewBlock] = []
        // An explicit stack: a file can nest deeply and the caller may be on a small cooperative stack.
        var stack: [SyntaxNode] = [parsed.tree.rootNode]
        while let node = stack.popLast() {
            if node.type == "macro_invocation" {
                if let block = macroBlock(node, trailing: nil, fullBytes: node.byteRange, in: parsed) {
                    blocks.append(block)
                    continue
                }
            }
            // The grammar sometimes reads `#Preview(traits: …) { … }` as a call of the macro with
            // the closure as a second suffix, depending on what follows it.
            if node.type == "call_expression", let callee = node.namedChild(at: 0), callee.type == "macro_invocation",
               let trailing = node.namedChildren(ofType: "call_suffix").first(where: { $0.firstNamedChild(ofType: "lambda_literal") != nil }),
               let block = macroBlock(callee, trailing: trailing, fullBytes: node.byteRange, in: parsed) {
                blocks.append(block)
                continue
            }
            // A preview's own closure never holds another one, and neither does a lambda or an expression.
            switch node.type {
            case "lambda_literal", "call_expression", "line_string_literal", "comment", "multiline_comment": continue
            default: break
            }
            stack.append(contentsOf: node.namedChildren)
        }
        return blocks
    }

    private static func macroBlock(
        _ node: SyntaxNode, trailing: SyntaxNode?, fullBytes: Range<Int>, in parsed: SwiftParsed
    ) -> SwiftPreviewBlock? {
        guard let name = node.firstNamedChild(ofType: "simple_identifier"), name.text == "Preview",
              let suffix = node.firstNamedChild(ofType: "call_suffix") else { return nil }

        var title: String?
        var traitParts: [String] = []
        var closure: SyntaxNode?
        var inTraits = false

        if let arguments = suffix.firstNamedChild(ofType: "value_arguments") {
            for argument in arguments.namedChildren(ofType: "value_argument") {
                let label = argument.child(byFieldName: "name")?.text
                let value = argument.child(byFieldName: "value")
                switch label {
                case nil where !inTraits:
                    if title == nil, let literal = value, literal.type == "line_string_literal" {
                        title = stringContents(of: literal, in: parsed)
                    }
                case "traits":
                    inTraits = true
                    if let value { traitParts.append(value.text) }
                case "body":
                    if let value, value.type == "lambda_literal" { closure = value }
                    inTraits = false
                case nil:
                    // `traits:` is variadic: the arguments after it carry no label.
                    if let value { traitParts.append(value.text) }
                default:
                    inTraits = false
                }
            }
        }
        if closure == nil { closure = suffix.firstNamedChild(ofType: "lambda_literal") }
        if closure == nil { closure = trailing?.firstNamedChild(ofType: "lambda_literal") }
        guard let closure else { return nil }

        let bytes = closure.byteRange
        guard bytes.count >= 2 else { return nil }
        let body = (bytes.lowerBound + 1)..<(bytes.upperBound - 1)
        let (previewables, contentStart) = leadingPreviewables(in: closure, body: body, parsed: parsed)

        return SwiftPreviewBlock(
            kind: .macro,
            title: title,
            index: 0,
            traits: traitParts.isEmpty ? nil : traitParts.joined(separator: ", "),
            fullBytes: fullBytes,
            bodyBytes: body,
            contentBytes: contentStart..<body.upperBound,
            previewables: previewables,
            line: parsed.text.position(atByte: fullBytes.lowerBound).line + 1
        )
    }

    /// `@Previewable var x = 1` declarations that open the closure, and where the content starts.
    private static func leadingPreviewables(
        in closure: SyntaxNode, body: Range<Int>, parsed: SwiftParsed
    ) -> ([SwiftPreviewBlock.Previewable], Int) {
        guard let statements = closure.firstNamedChild(ofType: "statements") else { return ([], body.lowerBound) }
        var found: [SwiftPreviewBlock.Previewable] = []
        var contentStart = body.lowerBound
        for statement in statements.namedChildren {
            guard statement.type == "property_declaration" else { break }
            let attributes = statement.namedChildren(ofType: "attribute")
            guard let marker = attributes.first(where: { attributeName($0) == "Previewable" }) else { break }
            guard let pattern = statement.child(byFieldName: "name"),
                  let identifier = pattern.child(byFieldName: "bound_identifier") ?? pattern.firstNamedChild(ofType: "simple_identifier")
            else { break }

            let full = statement.startByte..<statement.endByte
            // Remove `@Previewable` and the whitespace after it; the other attributes stay.
            var declaration = parsed.text.text(bytes: full)
            let markerLocal = (marker.startByte - full.lowerBound)..<(marker.endByte - full.lowerBound)
            let utf8 = Array(declaration.utf8)
            var end = markerLocal.upperBound
            while end < utf8.count, utf8[end] == 0x20 || utf8[end] == 0x09 || utf8[end] == 0x0A { end += 1 }
            declaration = String(decoding: utf8[..<markerLocal.lowerBound] + utf8[end...], as: UTF8.self)

            found.append(SwiftPreviewBlock.Previewable(
                name: identifier.text,
                text: parsed.text.text(bytes: full),
                declarationText: declaration,
                bytes: full
            ))
            contentStart = statement.endByte
        }
        return (found, contentStart)
    }

    private static func attributeName(_ attribute: SyntaxNode) -> String? {
        guard let type = attribute.firstNamedChild(ofType: "user_type") else { return nil }
        return type.text
    }

    private static func stringContents(of literal: SyntaxNode, in parsed: SwiftParsed) -> String {
        let full = parsed.text.text(bytes: literal.byteRange)
        guard full.hasPrefix("\""), full.hasSuffix("\""), full.count >= 2 else { return full }
        return String(full.dropFirst().dropLast())
    }

    // MARK: - PreviewProvider

    private static func providerBlocks(in parsed: SwiftParsed) -> [SwiftPreviewBlock] {
        var blocks: [SwiftPreviewBlock] = []
        func visit(_ declaration: SwiftFileModel.Declaration) {
            if declaration.kind.isNominalType,
               declaration.inherits.contains(where: { $0 == "PreviewProvider" || $0.hasSuffix(".PreviewProvider") }),
               let previews = declaration.members.first(where: {
                   $0.name == "previews" && $0.kind == .property && $0.isStatic
               }),
               previews.isComputed, !previews.bodyBytes.isEmpty {
                blocks.append(SwiftPreviewBlock(
                    kind: .provider(typeName: declaration.name),
                    title: nil,
                    index: 0,
                    traits: nil,
                    fullBytes: declaration.fullBytes,
                    bodyBytes: previews.bodyBytes,
                    contentBytes: previews.bodyBytes,
                    previewables: [],
                    line: parsed.text.position(atByte: declaration.nameBytes.lowerBound).line + 1
                ))
            }
            // A provider is a top-level type or lives in a type or extension.
            for member in declaration.members where member.kind.isNominalType || member.kind == .extension {
                visit(member)
            }
        }
        parsed.model.declarations.forEach(visit)
        return blocks
    }
}
