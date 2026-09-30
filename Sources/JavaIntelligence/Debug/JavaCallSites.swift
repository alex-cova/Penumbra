import Foundation

/// A method or constructor call on one line, for Smart Step Into.
public struct JavaLineCall: Sendable, Equatable {
    /// The name the debugger matches on method entry: the method's name, or `<init>` for `new`.
    public let methodName: String
    /// The call as written, shortened for a menu (`b(a())`, `new Point(…)`).
    public let displayText: String
    /// UTF-16 column of the call's name on its line.
    public let column: Int
}

/// Finds the calls a line makes, in the order they run: a call's receiver and arguments come
/// before the call itself, so `b(a())` lists `a` first.
public enum JavaCallSites {
    /// Calls that start on `line` (1-based) of `source`.
    public static func calls(onLine line: Int, in source: String) -> [JavaLineCall] {
        guard let tree = JavaSyntaxParser().parse(source) else { return [] }
        let bytes = tree.sourceBytes
        guard let range = JavaSourceLines.byteRange(ofLine: line, in: bytes) else { return [] }
        var calls: [JavaLineCall] = []
        collect(tree.rootNode, lineRange: range, bytes: bytes, into: &calls)
        return calls
    }

    /// Post-order: children (receiver, arguments) before the node.
    private static func collect(_ node: SyntaxNode, lineRange: Range<Int>, bytes: [UInt8], into calls: inout [JavaLineCall]) {
        guard node.endByte > lineRange.lowerBound, node.startByte < lineRange.upperBound else { return }
        // A lambda's body runs later, not as part of this line's evaluation.
        if node.type == "lambda_expression" { return }
        for child in node.namedChildren {
            collect(child, lineRange: lineRange, bytes: bytes, into: &calls)
        }
        switch node.type {
        case "method_invocation":
            guard let name = node.child(byFieldName: "name"), lineRange.contains(name.startByte) else { return }
            let arguments = node.child(byFieldName: "arguments")?.text ?? "()"
            calls.append(JavaLineCall(
                methodName: name.text,
                displayText: name.text + shorten(arguments),
                column: column(of: name.startByte, lineStart: lineRange.lowerBound, bytes: bytes)
            ))
        case "object_creation_expression":
            guard let type = node.child(byFieldName: "type"), lineRange.contains(type.startByte) else { return }
            let arguments = node.child(byFieldName: "arguments")?.text ?? "()"
            calls.append(JavaLineCall(
                methodName: "<init>",
                displayText: "new " + type.text + shorten(arguments),
                column: column(of: type.startByte, lineStart: lineRange.lowerBound, bytes: bytes)
            ))
        default:
            break
        }
    }

    private static func shorten(_ arguments: String) -> String {
        let flat = arguments.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        return flat.count <= 40 ? flat : "(…)"
    }

    private static func column(of byte: Int, lineStart: Int, bytes: [UInt8]) -> Int {
        String(decoding: bytes[lineStart..<min(byte, bytes.count)], as: UTF8.self).utf16.count
    }
}

/// Line lookups over a parsed file's UTF-8 bytes.
enum JavaSourceLines {
    /// Bytes of 1-based `line`, without its line break.
    static func byteRange(ofLine line: Int, in bytes: [UInt8]) -> Range<Int>? {
        guard line >= 1 else { return nil }
        var current = 1
        var start = 0
        var index = 0
        while index < bytes.count, current < line {
            if bytes[index] == 10 {
                current += 1
                start = index + 1
            }
            index += 1
        }
        guard current == line else { return nil }
        var end = start
        while end < bytes.count, bytes[end] != 10 { end += 1 }
        return start..<end
    }

    /// 1-based line of a byte offset.
    static func line(ofByte offset: Int, in bytes: [UInt8]) -> Int {
        var line = 1
        for index in 0..<min(max(0, offset), bytes.count) where bytes[index] == 10 { line += 1 }
        return line
    }
}

/// Checks that a breakpoint condition or watch is a Java expression, without resolving names.
public enum JavaExpressionSyntax {
    /// Nil when `expression` parses as an expression; otherwise what to tell the user.
    public static func problem(in expression: String) -> String? {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let wrapped = "class __Umbra { Object __value = (\(trimmed)\n); }"
        guard let tree = JavaSyntaxParser().parse(wrapped) else { return "Cannot parse the expression." }
        return tree.rootNode.hasError ? "Not a valid Java expression." : nil
    }
}
