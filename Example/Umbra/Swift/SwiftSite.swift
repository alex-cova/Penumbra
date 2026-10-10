import EditorIntelligence
import Foundation
import JavaIntelligence

/// What the caret is completing, decided from the text around it and the tree. A buffer being
/// typed in is full of syntax errors, so the dot and the expression before it are found from
/// bytes first and the tree only supplies the node that expression ends in.
enum SwiftSite {
    case none
    /// `receiver.|`: the chain before the dot and where it was written.
    case member(receiver: SwiftChain, at: Int)
    /// `.|` where the context decides the type (`let c: Color = .|`, `foo(.|)`).
    case implicitMember(at: Int)
    case type
    case importedModule
    case value

    private static let climbable: Set<String> = [
        "navigation_expression", "navigation_suffix", "call_expression", "call_suffix", "value_arguments",
        "constructor_expression", "constructor_suffix", "postfix_expression", "try_expression", "await_expression",
        "tuple_expression", "as_expression", "array_literal", "dictionary_literal", "line_string_literal",
        "multi_line_string_literal", "key_path_expression", "value_argument", "self_expression"
    ]

    private static let typeContexts: Set<String> = [
        "type_annotation", "user_type", "type_arguments", "inheritance_specifier", "function_type", "tuple_type_item",
        "array_type", "dictionary_type", "optional_type", "opaque_type", "existential_type", "protocol_composition_type",
        "type_constraint", "type_parameter", "typealias_declaration"
    ]

    private static let blockers: Set<String> = [
        "statements", "class_body", "enum_class_body", "protocol_body", "function_body", "source_file", "lambda_literal"
    ]

    /// - Parameters:
    ///   - byte: the caret.
    ///   - prefixStart: where the identifier being typed starts, in bytes.
    static func classify(byte: Int, prefixStart: Int, parsed: SwiftParsed) -> SwiftSite {
        let tree = parsed.tree
        for probe in [byte - 1, byte] where probe >= 0 && probe <= parsed.text.utf8.count {
            let node = tree.node(atByteOffset: probe)
            if SwiftNames.inCommentOrString(node) { return .none }
        }
        let bytes = parsed.text.utf8
        if prefixStart > 0, prefixStart <= bytes.count, bytes[prefixStart - 1] == 0x2E {
            return memberSite(dot: prefixStart - 1, parsed: parsed)
        }
        if isImportLine(at: byte, bytes: bytes) { return .importedModule }
        if isTypePosition(byte: byte, prefixStart: prefixStart, parsed: parsed) { return .type }
        return .value
    }

    private static func isImportLine(at byte: Int, bytes: [UInt8]) -> Bool {
        var start = min(byte, bytes.count)
        while start > 0, bytes[start - 1] != 0x0A { start -= 1 }
        let line = String(decoding: bytes[start..<min(byte, bytes.count)], as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        return line == "import" || line.hasPrefix("import ") || line.hasPrefix("@testable import")
    }

    private static func memberSite(dot: Int, parsed: SwiftParsed) -> SwiftSite {
        let bytes = parsed.text.utf8
        // `..<` and `...` are operators, not member access.
        if dot > 0, bytes[dot - 1] == 0x2E { return .none }
        var end = dot
        // `foo?.|` and `foo!.|`: the receiver ends before the `?` or `!`.
        if end > 0, bytes[end - 1] == 0x3F || bytes[end - 1] == 0x21, end > 1,
           isReceiverEnd(bytes[end - 2]) {
            end -= 1
        }
        // A leading dot on a new line continues the expression above it.
        var lookback = end
        while lookback > 0, bytes[lookback - 1] == 0x20 || bytes[lookback - 1] == 0x09
            || bytes[lookback - 1] == 0x0A || bytes[lookback - 1] == 0x0D {
            lookback -= 1
        }
        guard lookback > 0, isReceiverEnd(bytes[lookback - 1]) else { return .implicitMember(at: dot) }
        // `return .x` and `case .x`: a keyword before the dot, not an expression.
        if bytes[lookback - 1] != 0x29, bytes[lookback - 1] != 0x5D, bytes[lookback - 1] != 0x22 {
            var wordStart = lookback
            while wordStart > 0, isIdentifierByte(bytes[wordStart - 1]) { wordStart -= 1 }
            let word = String(decoding: bytes[wordStart..<lookback], as: UTF8.self)
            if ["return", "case", "in", "else", "default", "is", "as", "try", "await", "throw", "where", "if", "while"]
                .contains(word) {
                return .implicitMember(at: dot)
            }
        }
        let (chain, start) = chain(endingAt: lookback, parsed: parsed)
        return .member(receiver: chain, at: start)
    }

    /// The chain of the expression that ends at `end`: a run of plain names is read from the text
    /// (error recovery around a dangling dot or a half-typed call often leaves the tree with no node
    /// for it), anything with a call or a subscript in it from the tree.
    static func chain(endingAt end: Int, parsed: SwiftParsed) -> (chain: SwiftChain, start: Int) {
        let bytes = parsed.text.utf8
        if let found = textChain(endingAt: end, bytes: bytes) { return found }
        guard end > 0 else { return (.unknown, 0) }
        let leaf = parsed.tree.node(atByteOffset: end - 1)
        var node = leaf
        var hops = 0
        while let parent = node.parent, parent.endByte == end, hops < 24 {
            if climbable.contains(parent.type) || !node.isNamed {
                node = parent
                hops += 1
            } else {
                break
            }
        }
        let walker = SwiftModelWalker(tree: parsed.tree, text: parsed.text)
        var chain = walker.makeChain(node)
        if case .unknown = chain.base, chain.steps.isEmpty, SwiftNames.isName(leaf.type) {
            chain = SwiftChain(base: .name(leaf.text, at: leaf.startByte), steps: [])
        }
        return (chain, node.startByte)
    }

    /// The chain of plain names ending at `end` (`a.b?.c`), or nil when anything else (a call, a
    /// subscript, a literal) is part of the expression.
    static func textChain(endingAt end: Int, bytes: [UInt8]) -> (chain: SwiftChain, start: Int)? {
        var parts: [(name: String, start: Int)] = []
        var position = min(end, bytes.count)
        while position > 0 {
            var start = position
            while start > 0, isIdentifierByte(bytes[start - 1]) { start -= 1 }
            guard start < position, !(bytes[start] >= 0x30 && bytes[start] <= 0x39) else { return nil }
            parts.append((String(decoding: bytes[start..<position], as: UTF8.self), start))
            position = start
            var back = position
            while back > 0, bytes[back - 1] == 0x20 || bytes[back - 1] == 0x09
                || bytes[back - 1] == 0x0A || bytes[back - 1] == 0x0D {
                back -= 1
            }
            if back > 0, bytes[back - 1] == 0x3F || bytes[back - 1] == 0x21 { back -= 1 }
            if back > 0, bytes[back - 1] == 0x2E {
                if back > 1, bytes[back - 2] == 0x2E { return nil }
                position = back - 1
                while position > 0, bytes[position - 1] == 0x20 || bytes[position - 1] == 0x09
                    || bytes[position - 1] == 0x0A || bytes[position - 1] == 0x0D {
                    position -= 1
                }
                // The chain continues to the left of the dot; it must be a name there too.
                guard position > 0, isIdentifierByte(bytes[position - 1]) else { return nil }
            } else {
                break
            }
        }
        guard let first = parts.last else { return nil }
        let ordered = Array(parts.reversed())
        let chain = SwiftChain(
            base: .name(first.name, at: first.start),
            steps: ordered.dropFirst().map { .member($0.name) }
        )
        return (chain, first.start)
    }

    private static func isReceiverEnd(_ byte: UInt8) -> Bool {
        isIdentifierByte(byte) || byte == 0x29 || byte == 0x5D || byte == 0x22 || byte == 0x7D || byte == 0x3E
    }

    private static func isIdentifierByte(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
            || byte == 0x5F || byte >= 0x80
    }

    private static func isTypePosition(byte: Int, prefixStart: Int, parsed: SwiftParsed) -> Bool {
        let bytes = parsed.text.utf8
        // `-> |`, `as |`, `is |`: only a type fits.
        var back = min(prefixStart, bytes.count)
        while back > 0, bytes[back - 1] == 0x20 { back -= 1 }
        if back >= 2, bytes[back - 1] == 0x3E, bytes[back - 2] == 0x2D { return true }
        var wordStart = back
        while wordStart > 0, isIdentifierByte(bytes[wordStart - 1]) { wordStart -= 1 }
        let word = String(decoding: bytes[wordStart..<back], as: UTF8.self)
        if word == "as" || word == "is" { return true }
        if back > 0, bytes[back - 1] == 0x3F || bytes[back - 1] == 0x21, word.isEmpty {
            var before = back - 1
            while before > 0, isIdentifierByte(bytes[before - 1]) { before -= 1 }
            let previous = String(decoding: bytes[before..<(back - 1)], as: UTF8.self)
            if previous == "as" { return true }
        }
        for probe in [prefixStart - 1, byte - 1, byte] where probe >= 0 && probe <= bytes.count {
            var node: SyntaxNode? = parsed.tree.node(atByteOffset: probe)
            var hops = 0
            while let current = node, hops < 8 {
                if typeContexts.contains(current.type) {
                    // A property's initializer sits beside its annotation, not inside it.
                    return current.type != "typealias_declaration" || byte > current.startByte
                }
                if blockers.contains(current.type) { break }
                node = current.parent
                hops += 1
            }
        }
        return false
    }
}
