import EditorIntelligence
import Foundation

enum JavaRefactoringText {
    static func fullText(of document: Document) -> String {
        JavaNavigationText.fullText(of: document)
    }

    static func selectionByteRange(in source: String, selection: Selection) -> Range<Int>? {
        guard selection.additionalRanges.isEmpty else { return nil }
        let range = selection.range
        guard !range.isEmpty else { return nil }
        return byteRange(forUTF16Range: range.start.utf16Offset..<range.end.utf16Offset, in: source)
    }

    static func caretUTF16Offset(in cursor: Cursor, source: String) -> Int? {
        let offset = cursor.position.utf16Offset
        guard offset >= 0, offset <= (source as NSString).length else { return nil }
        return offset
    }

    static func identifierToken(atUTF16Offset offset: Int, in source: String) -> (SyntaxNode, JavaSyntaxTree)? {
        guard let tree = JavaSyntaxParser().parse(source) else { return nil }
        let byteOffset = JavaNavigationText.utf8ByteOffset(forUTF16Offset: offset, in: source)
        func isName(_ node: SyntaxNode) -> Bool {
            node.type == "identifier" || node.type == "type_identifier"
        }
        let leaf = tree.node(atByteOffset: byteOffset)
        if leaf.byteRange.contains(byteOffset), isName(leaf) { return (leaf, tree) }
        let before = tree.node(atByteOffset: max(0, byteOffset - 1))
        guard isName(before), before.byteRange.upperBound == byteOffset else { return nil }
        return (before, tree)
    }

    static func byteRange(forUTF16Range range: Range<Int>, in source: String) -> Range<Int>? {
        let lower = JavaNavigationText.utf8ByteOffset(forUTF16Offset: range.lowerBound, in: source)
        let upper = JavaNavigationText.utf8ByteOffset(forUTF16Offset: range.upperBound, in: source)
        guard lower <= upper else { return nil }
        return lower..<upper
    }

    static func trimmedByteRange(_ range: Range<Int>, in source: String) -> Range<Int>? {
        let bytes = Array(source.utf8)
        guard range.lowerBound >= 0, range.upperBound <= bytes.count, range.lowerBound < range.upperBound else { return nil }
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper, bytes[lower].asciiWhitespace { lower += 1 }
        while upper > lower, bytes[upper - 1].asciiWhitespace { upper -= 1 }
        guard lower < upper else { return nil }
        return lower..<upper
    }

    static func lineText(forByteRange range: Range<Int>, in source: String) -> String {
        let ns = source as NSString
        let start = JavaNavigationText.utf16Offset(forByte: range.lowerBound, in: source)
        let end = JavaNavigationText.utf16Offset(forByte: range.upperBound, in: source)
        let lineStart = ns.lineRange(for: NSRange(location: start, length: 0)).location
        let lineEnd = ns.lineRange(for: NSRange(location: end, length: 0)).upperBound
        return ns.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
    }

    static func textRange(for byteRange: Range<Int>, in source: String) -> EditorIntelligence.TextRange {
        JavaNavigationText.textRange(for: byteRange, in: source)
    }

    static func planEntry(
        url: URL,
        byteRange: Range<Int>,
        oldText: String,
        newText: String,
        source: String,
        description: String? = nil
    ) -> WorkspaceEditPlanEntry {
        WorkspaceEditPlanEntry(
            url: url.standardizedFileURL,
            range: textRange(for: byteRange, in: source),
            oldText: oldText,
            newText: newText,
            lineText: lineText(forByteRange: byteRange, in: source),
            description: description
        )
    }

    static func validateIdentifier(_ name: String) -> String? {
        RenameTarget.validateIdentifier(name)
    }

    static func typeSourceText(_ type: JavaTypeRef) -> String {
        switch type {
        case .primitive(let primitive):
            return primitive.rawValue
        case .void:
            return "void"
        case .classType(_, let arguments, _):
            let base = type.simpleDisplayName
            guard !arguments.isEmpty else { return base }
            let args = arguments.map(typeArgumentSourceText).joined(separator: ", ")
            return "\(base)<\(args)>"
        case .array(let element):
            return "\(typeSourceText(element))[]"
        case .typeVariable(let name):
            return name
        case .wildcard:
            return "Object"
        case .unresolved(let simpleName, let arguments):
            guard !arguments.isEmpty else { return simpleName }
            let args = arguments.map(typeArgumentSourceText).joined(separator: ", ")
            return "\(simpleName)<\(args)>"
        }
    }

    private static func typeArgumentSourceText(_ argument: JavaTypeArgument) -> String {
        switch argument {
        case .type(let type):
            return typeSourceText(type)
        case .wildcard(let bound):
            guard let bound else { return "?" }
            switch bound {
            case .extends(let type): return "? extends \(typeSourceText(type))"
            case .superBound(let type): return "? super \(typeSourceText(type))"
            }
        }
    }

    static func suggestedName(for expression: SyntaxNode) -> String {
        switch expression.type {
        case "method_invocation":
            if let name = expression.child(byFieldName: "name")?.text {
                return suggestedName(fromMethodName: name)
            }
        case "field_access":
            if let field = expression.child(byFieldName: "field")?.text { return decapitalize(field) }
        case "identifier", "type_identifier":
            return decapitalize(expression.text)
        case "string_literal", "character_literal", "decimal_integer_literal", "decimal_floating_point_literal",
             "hex_integer_literal", "octal_integer_literal", "binary_integer_literal", "true", "false", "null_literal":
            return "value"
        default:
            break
        }
        return "result"
    }

    static func suggestedMethodName(fromExpression name: String) -> String {
        suggestedName(fromMethodName: name)
    }

    private static func suggestedName(fromMethodName name: String) -> String {
        if name.hasPrefix("get"), name.count > 3, name.dropFirst(3).first?.isUppercase == true {
            return decapitalize(String(name.dropFirst(3)))
        }
        if name.hasPrefix("is"), name.count > 2, name.dropFirst(2).first?.isUppercase == true {
            return decapitalize(String(name.dropFirst(2)))
        }
        return decapitalize(name)
    }

    private static func decapitalize(_ name: String) -> String {
        guard let first = name.first else { return "result" }
        if name.count == 1 { return String(first).lowercased() }
        if name.dropFirst().allSatisfy({ $0.isUppercase || !$0.isLetter }) {
            return name.lowercased()
        }
        return String(first).lowercased() + name.dropFirst()
    }
}

private extension UInt8 {
    var asciiWhitespace: Bool {
        self == 32 || self == 9 || self == 10 || self == 13
    }
}
