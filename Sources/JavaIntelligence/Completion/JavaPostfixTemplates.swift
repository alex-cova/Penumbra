import EditorIntelligence
import Foundation

/// IntelliJ-style postfix completion: `flag.if` → `if (flag) { … }`, `items.for` →
/// `for (Item item : items) { … }`. Offered after `expr.` once a letter is typed, only when the
/// receiver's type fits the template (`.for` needs an array or an `Iterable`, `.nn` a reference
/// type, `.if`/`.not` a boolean). Statement templates also need `expr` to start a statement.
///
/// Each item replaces the typed prefix with the finished code and carries one additional edit
/// that deletes `expr.` in front of it, which the controller applies in the same undo group.
struct JavaPostfixTemplates {
    let text: String
    let bytes: [UInt8]
    /// Byte range of the receiver expression, and the byte offset of its trigger `.`.
    let expression: Range<Int>
    let dotOffset: Int
    let factory: JavaCompletionItemFactory
    let source: String
    /// Names already declared at the caret, which a new variable must not reuse.
    let takenNames: Set<String>

    func items(receiverType type: JavaTypeRef, elementType: JavaTypeRef?, isIterable: Bool) -> [CompletionItem] {
        let expressionText = String(decoding: bytes[expression], as: UTF8.self)
        let startsStatement = Self.startsStatement(bytes: bytes, at: expression.lowerBound)
        let indentation = Self.lineIndentation(bytes: bytes, at: expression.lowerBound)
        let step = indentation.contains("\t") ? "\t" : "    "
        let inner = indentation + step
        let isBoolean = type == .primitive(.boolean) || type.erasedQualifiedName == "java.lang.Boolean"
        let isReference: Bool = {
            switch type {
            case .primitive, .void: return false
            default: return true
            }
        }()
        let typeText = Self.sourceText(type)
        var result: [CompletionItem] = []

        func add(_ label: String, _ description: String, _ body: String, caretMarker: String = "|") {
            // `|` in `body` marks where the caret goes; it is removed from the inserted text.
            let caret = (body as NSString).range(of: caretMarker)
            let insert = caret.location == NSNotFound ? body : (body as NSString).replacingCharacters(in: caret, with: "")
            result.append(CompletionItem(
                label: label, insertText: insert, kind: .snippet, range: factory.range, source: source,
                filterText: label, detail: description, additionalEdits: [deleteReceiverEdit()],
                priority: JavaCompletionPriority.keyword, caretOffset: caret.location == NSNotFound ? nil : caret.location,
                allowsAutoInsert: false
            ))
        }

        if isBoolean {
            add("not", "!expr", "!\(parenthesized(expressionText))|")
            if startsStatement {
                add("if", "if (expr)", "if (\(expressionText)) {\n\(inner)|\n\(indentation)}")
                add("while", "while (expr)", "while (\(expressionText)) {\n\(inner)|\n\(indentation)}")
            }
        }
        if startsStatement {
            if isReference {
                add("nn", "if (expr != null)", "if (\(expressionText) != null) {\n\(inner)|\n\(indentation)}")
                add("null", "if (expr == null)", "if (\(expressionText) == null) {\n\(inner)|\n\(indentation)}")
            }
            if let elementType, isIterable {
                let element = Self.sourceText(elementType)
                let name = unique(Self.elementName(forCollection: expressionText, elementType: elementType))
                add("for", "for (\(element) \(name) : expr)", "for (\(element) \(name) : \(expressionText)) {\n\(inner)|\n\(indentation)}")
            }
            if type == .primitive(.int) || type == .primitive(.long) {
                let counter = type == .primitive(.long) ? "long" : "int"
                add("fori", "for (i < expr)", "for (\(counter) i = 0; i < \(expressionText); i++) {\n\(inner)|\n\(indentation)}")
            } else if case .array = type {
                add("fori", "for (i < expr.length)", "for (int i = 0; i < \(expressionText).length; i++) {\n\(inner)|\n\(indentation)}")
            }
            if type != .void {
                let name = unique(Self.variableName(forExpression: expressionText, type: type))
                add("var", "\(typeText) name = expr", "\(typeText) \(name)| = \(expressionText);")
                add("return", "return expr", "return \(expressionText);|")
                add("sout", "System.out.println(expr)", "System.out.println(\(expressionText));|")
            }
        }
        return result
    }

    /// A type as the generated code writes it: simple names, with nested types kept behind their
    /// outer type (`Map.Entry<String, User>`), since an on-demand import doesn't bring a nested
    /// type into scope. Types the file doesn't import yet are written the same way; the template
    /// doesn't add imports.
    static func sourceText(_ type: JavaTypeRef) -> String {
        switch type {
        case .classType(let name, let arguments, _):
            let segments = name.split(separator: ".").map(String.init)
            let firstType = segments.firstIndex { $0.first?.isUppercase == true } ?? max(0, segments.count - 1)
            let base = segments[firstType...].joined(separator: ".")
            guard !arguments.isEmpty else { return base }
            return "\(base)<\(arguments.map(sourceText).joined(separator: ", "))>"
        case .array(let element):
            return "\(sourceText(element))[]"
        default:
            return JavaCompletionItemFactory.display(type)
        }
    }

    private static func sourceText(_ argument: JavaTypeArgument) -> String {
        switch argument {
        case .type(let type): return sourceText(type)
        case .wildcard(nil): return "?"
        case .wildcard(.extends(let type)?): return "? extends \(sourceText(type))"
        case .wildcard(.superBound(let type)?): return "? super \(sourceText(type))"
        }
    }

    /// `name`, or `name1`, `name2`, … when a local already uses it.
    private func unique(_ name: String) -> String {
        guard takenNames.contains(name) else { return name }
        var counter = 1
        while takenNames.contains("\(name)\(counter)") { counter += 1 }
        return "\(name)\(counter)"
    }

    /// The loop variable for iterating `collection`: its name made singular (`users` → `user`,
    /// `entries` → `entry`), else the element type's name.
    static func elementName(forCollection collection: String, elementType: JavaTypeRef) -> String {
        let last = String(collection.split(separator: ".").last ?? Substring(collection))
        if last.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
            if last.hasSuffix("ies"), last.count > 3 { return String(last.dropLast(3)) + "y" }
            if last.hasSuffix("s"), !last.hasSuffix("ss"), last.count > 1 { return String(last.dropLast()) }
        }
        return variableName(forType: elementType, avoiding: collection)
    }

    private func parenthesized(_ expression: String) -> String {
        expression.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "(" || $0 == ")" } ? expression : "(\(expression))"
    }

    /// Deletes `expr.` (from the expression start through the trigger dot).
    private func deleteReceiverEdit() -> TextEdit {
        TextEdit(range: TextRange(start: position(ofByte: expression.lowerBound), end: position(ofByte: dotOffset + 1)), replacement: "")
    }

    private func position(ofByte offset: Int) -> TextPosition {
        let prefix = String(decoding: bytes[0..<offset], as: UTF8.self)
        let utf16 = (prefix as NSString).length
        var line = 0
        var lineStart = prefix.startIndex
        for index in prefix.indices where prefix[index] == "\n" {
            line += 1
            lineStart = prefix.index(after: index)
        }
        return TextPosition(line: line, column: prefix[lineStart...].utf16.count, utf16Offset: utf16)
    }

    /// Whether only whitespace and comments separate `offset` from the previous statement.
    static func startsStatement(bytes: [UInt8], at offset: Int) -> Bool {
        let before = JavaReceiverScanner.skipTrivia(bytes, before: offset) ?? offset
        guard before > 0 else { return true }
        return [UInt8(ascii: ";"), UInt8(ascii: "{"), UInt8(ascii: "}")].contains(bytes[before - 1])
    }

    static func lineIndentation(bytes: [UInt8], at offset: Int) -> String {
        var lineStart = offset
        while lineStart > 0, bytes[lineStart - 1] != UInt8(ascii: "\n") { lineStart -= 1 }
        var end = lineStart
        while end < bytes.count, bytes[end] == UInt8(ascii: " ") || bytes[end] == UInt8(ascii: "\t") { end += 1 }
        return String(decoding: bytes[lineStart..<end], as: UTF8.self)
    }

    /// `getAddress()` → `address`, `user.getName()` → `name`, otherwise the type's name.
    static func variableName(forExpression expression: String, type: JavaTypeRef) -> String {
        let lastSegment = expression.split(separator: ".").last.map(String.init) ?? expression
        let call = lastSegment.prefix { $0 != "(" }
        for prefix in ["get", "is"] where call.hasPrefix(prefix) && call.count > prefix.count {
            let rest = call.dropFirst(prefix.count)
            if rest.first?.isUppercase == true { return rest.prefix(1).lowercased() + rest.dropFirst() }
        }
        return variableName(forType: type, avoiding: expression)
    }

    static func variableName(forType type: JavaTypeRef, avoiding taken: String) -> String {
        var name: String
        switch type {
        case .primitive(let primitive): name = String(primitive.rawValue.prefix(1))
        case .array(let element): name = variableName(forType: element, avoiding: taken) + "s"
        default:
            let simple = JavaCompletionItemFactory.display(type).prefix { $0 != "<" }
            name = simple.prefix(1).lowercased() + simple.dropFirst()
        }
        if name.isEmpty || name == taken || JavaCompletionProvider.keywords.contains(name) { name += "1" }
        return name
    }
}
