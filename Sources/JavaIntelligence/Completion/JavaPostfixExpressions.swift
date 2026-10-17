import EditorIntelligence
import Foundation

/// Expressions that end at a postfix dot, innermost first.
///
/// Completion parses `a + b.var` as `a + b.var__penumbra__`. The field access's object is `b`;
/// its parent `a + b` ends at the same place. A parent that continues past that point — the
/// closing `)` of `(a + b.var)`, or the call around it — is not a candidate. At most three.
enum JavaPostfixExpressions {
    private static let expandable: Set<String> = [
        "binary_expression", "unary_expression", "parenthesized_expression", "cast_expression",
        "ternary_expression", "assignment_expression", "update_expression"
    ]

    static func ranges(in tree: JavaSyntaxTree, dotOffset: Int, bytes: [UInt8]) -> [Range<Int>] {
        if let selector = selector(in: tree, dotOffset: dotOffset),
           let object = selector.child(byFieldName: "object") ?? selector.namedChildren.first,
           !object.hasError, !object.isMissing {
            // A parent such as `a + b.var` spans the field name too. The expression that ends at
            // the dot stops where the field's object stops, so the dummy identifier stays out.
            let end = object.endByte
            var found: [Range<Int>] = [object.startByte..<end]
            var current = object.parent
            while let node = current, found.count < 3 {
                if node.byteRange == selector.byteRange {
                    current = node.parent
                    continue
                }
                if node.endByte > selector.endByte { break }
                if expandable.contains(node.type), node.startByte < found[found.count - 1].lowerBound {
                    found.append(node.startByte..<end)
                }
                current = node.parent
            }
            return found
        }
        if let range = JavaReceiverScanner.receiverRange(in: bytes, dotOffset: dotOffset) {
            return [range]
        }
        return []
    }

    static func text(bytes: [UInt8], range: Range<Int>) -> String {
        let lower = min(max(0, range.lowerBound), bytes.count)
        let upper = min(max(lower, range.upperBound), bytes.count)
        return String(decoding: bytes[lower..<upper], as: UTF8.self)
    }

    /// The field access or call whose name starts just after this dot.
    private static func selector(in tree: JavaSyntaxTree, dotOffset: Int) -> SyntaxNode? {
        var current: SyntaxNode? = tree.node(atByteOffset: dotOffset + 1)
        while let node = current {
            switch node.type {
            case "field_access", "method_invocation":
                let object = node.child(byFieldName: "object")
                let name = node.child(byFieldName: node.type == "field_access" ? "field" : "name")
                if let object, let name, object.endByte <= dotOffset, name.startByte > dotOffset,
                   !object.hasError, !object.isMissing {
                    return node
                }
                current = node.parent
            case "ERROR", "block", "class_body", "program":
                return nil
            default:
                current = node.parent
            }
        }
        return nil
    }
}

/// One expression a postfix template can wrap, already typed.
struct JavaPostfixCandidate {
    var range: Range<Int>
    var text: String
    var type: JavaTypeRef
    var elementType: JavaTypeRef?
    var isIterable: Bool
    var isTypeReference: Bool
    var isEnum: Bool
    var isThrowable: Bool
    var isAutoCloseable: Bool
    var isList: Bool
    var hasTypeParameters: Bool
    var matchingCustom: [JavaPostfixCustomTemplate]
}

/// How `Optional`, `Objects` and `Arrays` should be written in a template body.
struct JavaPostfixImports {
    var optionalName = "Optional"
    var optionalEdit: TextEdit?
    var objectsName = "Objects"
    var objectsEdit: TextEdit?
    var arraysName = "Arrays"
    var arraysEdit: TextEdit?
}
