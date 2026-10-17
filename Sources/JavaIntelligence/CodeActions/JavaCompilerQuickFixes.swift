import EditorIntelligence
import Foundation

/// The first key-driven quick fixes, keyed on `Diagnostic.code` (`javac:<key>`) so the same
/// fixes serve the native checks later: the import fix (which already existed message-first),
/// *Add throws* / *Surround with try/catch* for unreported exceptions, *Implement methods* for
/// unimplemented abstract methods, and *Add return statement* for missing returns.
///
/// Everything here is syntactic (tree plus index lookups); nothing awaits attribution.
enum JavaCompilerQuickFixes {
    /// Actions for the keyed `javac` diagnostics on the caret's line.
    static func actions(
        in text: String, at position: TextPosition, diagnostics: [Diagnostic], index: JavaIndex
    ) async -> [CodeAction] {
        guard let tree = JavaSyntaxParser().parse(text) else { return [] }
        let ns = text as NSString
        let caret = min(max(0, position.utf16Offset), ns.length)
        let caretLineNumber = ns.substring(to: caret).components(separatedBy: "\n").count - 1
        var actions: [CodeAction] = []
        for diagnostic in diagnostics where diagnostic.source == "javac" {
            // The caret may sit anywhere the diagnostic covers (a missing-return span covers
            // the whole body), not just on its first line.
            let span = diagnostic.range.start.line...diagnostic.range.end.line
            guard span.contains(caretLineNumber) else { continue }
            switch diagnostic.code {
            case "javac:compiler.err.unreported.exception.need.to.catch.or.throw":
                actions += unreportedExceptionActions(diagnostic, in: text, tree: tree, at: caret)
            case "javac:compiler.err.does.not.override.abstract":
                actions += await implementMethodsAction(diagnostic, in: text, tree: tree, index: index)
            case "javac:compiler.err.missing.ret.stmt":
                actions += missingReturnAction(diagnostic, in: text, tree: tree)
            default:
                break
            }
        }
        return actions
    }

    // MARK: - Unreported exception

    private static let unreportedPattern = try! NSRegularExpression(pattern: #"unreported exception ([^;]+);"#)

    private static func unreportedExceptionActions(
        _ diagnostic: Diagnostic, in text: String, tree: JavaSyntaxTree, at caret: Int
    ) -> [CodeAction] {
        let message = diagnostic.message.replacingOccurrences(of: "\n", with: " ")
        guard let match = unreportedPattern.firstMatch(in: message, range: NSRange(location: 0, length: (message as NSString).length)),
              match.numberOfRanges == 2 else { return [] }
        let thrown = (message as NSString).substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
        guard !thrown.isEmpty else { return [] }
        var actions: [CodeAction] = []
        if let method = enclosingMethod(of: caret, in: text, tree: tree),
           let name = method.child(byFieldName: "name")?.text {
            let bytes = tree.sourceBytes
            if let throwsNode = method.namedChildren.first(where: { $0.type == "throws" }) {
                let end = JavaImportInserter.textPosition(forByteOffset: throwsNode.byteRange.upperBound, in: bytes)
                let pos = TextPosition(line: end.line, column: end.column, utf16Offset: end.utf16Offset)
                actions.append(CodeAction(
                    title: "Add throws \(thrown) to '\(name)'", kind: "quickfix",
                    edits: [TextEdit(range: TextRange(start: pos, end: pos), replacement: ", \(thrown)")]
                ))
            } else if let body = method.child(byFieldName: "body") {
                let at = JavaImportInserter.textPosition(forByteOffset: body.byteRange.lowerBound, in: bytes)
                let pos = TextPosition(line: at.line, column: at.column, utf16Offset: at.utf16Offset)
                actions.append(CodeAction(
                    title: "Add throws \(thrown) to '\(name)'", kind: "quickfix",
                    edits: [TextEdit(range: TextRange(start: pos, end: pos), replacement: "throws \(thrown) ")]
                ))
            }
        }
        if let statement = innermostStatement(at: caret, in: text, tree: tree) {
            actions.append(surroundWithTryCatch(statement, thrown: thrown, in: text, tree: tree))
        }
        return actions
    }

    // MARK: - Implement methods

    private static let abstractPattern = try! NSRegularExpression(
        pattern: #"^(\S+) is not abstract and does not override abstract method (\w+)\(([^)]*)\) in (\S+)$"#)

    private static func implementMethodsAction(
        _ diagnostic: Diagnostic, in text: String, tree: JavaSyntaxTree, index: JavaIndex
    ) async -> [CodeAction] {
        let message = diagnostic.message.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard let match = abstractPattern.firstMatch(in: message, range: NSRange(location: 0, length: (message as NSString).length)),
              match.numberOfRanges == 5 else { return [] }
        let ns = message as NSString
        let className = ns.substring(with: match.range(at: 1))
        let methodName = ns.substring(with: match.range(at: 2))
        let messageParams = ns.substring(with: match.range(at: 3))
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).split(separator: ".").last.map(String.init) ?? "" }
        let ownerName = ns.substring(with: match.range(at: 4))
        let owner: JavaClassStub?
        if ownerName.contains(".") {
            owner = await index.classStub(qualifiedName: ownerName)
        } else {
            owner = await index.classes(simpleName: ownerName, limit: 10).first
        }
        guard let owner else { return [] }
        let sameName = owner.methods.filter { !$0.isConstructor && $0.name == methodName }
        guard !sameName.isEmpty else { return [] }
        let byArity = sameName.filter { $0.parameters.count == messageParams.count }
        let candidates = byArity.isEmpty ? sameName : byArity
        let erased = candidates.filter { method in
            method.parameters.map { JavaSignatureText.text(of: $0.type).split(separator: "<").first.map(String.init) ?? "" }
                == messageParams
        }
        guard let method = erased.first ?? candidates.first else { return [] }
        guard let host = innermostType(named: className, in: tree),
              let body = host.namedChildren.first(where: { $0.type == "class_body" }) else { return [] }
        let bodyIndent = indent(ofLineContaining: body.byteRange.lowerBound, in: tree, text: text)
        let memberIndent = bodyIndent + "    "
        var header = "@Override\n" + memberIndent
        header += method.modifiers.contains(.protectedFlag) ? "protected " : "public "
        if !method.typeParameters.isEmpty {
            header += "<" + method.typeParameters.map { param in
                param.bounds.isEmpty ? param.name
                    : "\(param.name) extends \(param.bounds.map { JavaSignatureText.text(of: $0) }.joined(separator: " & "))"
            }.joined(separator: ", ") + "> "
        }
        let returnText = JavaSignatureText.text(of: method.returnType)
        header += "\(returnText) \(method.name)("
        header += method.parameters.enumerated().map { index, parameter in
            var type = JavaSignatureText.text(of: parameter.type)
            if method.modifiers.contains(.varargs), index == method.parameters.count - 1, type.hasSuffix("[]") {
                type = String(type.dropLast(2)) + "..."
            }
            return "\(type) \(parameter.name ?? "arg\(index)")"
        }.joined(separator: ", ") + ")"
        if !method.thrownTypes.isEmpty {
            header += " throws " + method.thrownTypes.map { JavaSignatureText.text(of: $0) }.joined(separator: ", ")
        }
        let bodyText: String
        if returnText == "void" {
            bodyText = " {\n\(memberIndent)}"
        } else if let defaultValue = defaultReturnValue(forTypeNamed: returnText) {
            bodyText = " {\n\(memberIndent)    return \(defaultValue);\n\(memberIndent)}"
        } else {
            return []
        }
        // Exactly one blank line before the new member: none inside an empty body, no double.
        let bodySlice = String(bytes: tree.sourceBytes[body.byteRange], encoding: .utf8) ?? ""
        let bodyInnerIsWhitespace = bodySlice.dropFirst().dropLast()
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let caretUTF16 = JavaImportInserter.textPosition(forByteOffset: body.byteRange.upperBound - 1, in: tree.sourceBytes).utf16Offset
        let beforeInsertion = (text as NSString).substring(to: min(max(0, caretUTF16), (text as NSString).length))
        let prefix: String
        if beforeInsertion.hasSuffix("\n\n") {
            prefix = ""
        } else if bodyInnerIsWhitespace {
            prefix = beforeInsertion.hasSuffix("\n") ? "" : "\n"
        } else {
            prefix = "\n"
        }
        let insertion = "\(prefix)\(memberIndent)\(header)\(bodyText)\n\(bodyIndent)"
        let at = JavaImportInserter.textPosition(forByteOffset: body.byteRange.upperBound - 1, in: tree.sourceBytes)
        let pos = TextPosition(line: at.line, column: at.column, utf16Offset: at.utf16Offset)
        return [CodeAction(
            title: "Implement methods", kind: "quickfix",
            edits: [TextEdit(range: TextRange(start: pos, end: pos), replacement: insertion)]
        )]
    }

    // MARK: - Missing return

    private static func missingReturnAction(_ diagnostic: Diagnostic, in text: String, tree: JavaSyntaxTree) -> [CodeAction] {
        let range = ProblemLocator.nsRange(for: diagnostic.range, in: text)
        guard let method = enclosingMethod(of: range.location, in: text, tree: tree),
              let returnType = method.child(byFieldName: "type")?.text,
              let defaultValue = defaultReturnValue(forTypeNamed: returnType),
              let body = method.child(byFieldName: "body") else { return [] }
        let closingIndent = indent(ofLineContaining: body.byteRange.upperBound - 1, in: tree, text: text)
        let at = JavaImportInserter.textPosition(forByteOffset: body.byteRange.upperBound - 1, in: tree.sourceBytes)
        let pos = TextPosition(line: at.line, column: at.column, utf16Offset: at.utf16Offset)
        return [CodeAction(
            title: "Add return statement", kind: "quickfix",
            edits: [TextEdit(
                range: TextRange(start: pos, end: pos),
                // The brace line's own indent stays in front; the statement adds one level and
                // the replacement re-emits the brace line's indent for the closing brace.
                replacement: "    return \(defaultValue);\n\(closingIndent)"
            )]
        )]
    }

    /// A compilable default for a simple type name; `nil` for `void` and unrecognized shapes.
    static func defaultReturnValue(forTypeNamed name: String) -> String? {
        switch name {
        case "boolean": return "false"
        case "char": return "'\\0'"
        case "float", "double": return "0.0"
        case "byte", "short", "int", "long": return "0"
        case "void": return nil
        default:
            // Arrays, qualified and generic names are references; a bare unknown reads as one too.
            if name.hasSuffix("[]") || name.contains(".") || name.contains("<") { return "null" }
            guard let first = name.first else { return nil }
            return first.isUppercase ? "null" : nil
        }
    }

    // MARK: - Tree helpers

    /// The innermost method or constructor declaration containing the UTF-16 offset.
    private static func enclosingMethod(of utf16Offset: Int, in text: String, tree: JavaSyntaxTree) -> SyntaxNode? {
        let byteOffset = JavaNavigationText.utf8ByteOffset(forUTF16Offset: utf16Offset, in: text)
        var best: SyntaxNode?
        var stack = [tree.rootNode]
        while let node = stack.popLast() {
            guard node.byteRange.contains(byteOffset) else { continue }
            if node.type == "method_declaration" || node.type == "constructor_declaration" { best = node }
            for index in (0..<node.namedChildCount).reversed() {
                stack.append(node.namedChild(at: index)!)
            }
        }
        return best
    }

    /// The innermost class-like declaration with this simple name.
    private static func innermostType(named name: String, in tree: JavaSyntaxTree) -> SyntaxNode? {
        let simple = name.split(separator: ".").last.map(String.init) ?? name
        var found: SyntaxNode?
        var stack = [tree.rootNode]
        while let node = stack.popLast() {
            if (node.type == "class_declaration" || node.type == "interface_declaration"
                || node.type == "enum_declaration" || node.type == "record_declaration"
                || node.type == "annotation_type_declaration"),
               node.child(byFieldName: "name")?.text == simple {
                found = node
            }
            for index in (0..<node.namedChildCount).reversed() {
                stack.append(node.namedChild(at: index)!)
            }
        }
        return found
    }

    /// The smallest statement containing the UTF-16 offset: the ancestor whose parent is a block.
    private static func innermostStatement(at utf16Offset: Int, in text: String, tree: JavaSyntaxTree) -> SyntaxNode? {
        let byteOffset = JavaNavigationText.utf8ByteOffset(forUTF16Offset: utf16Offset, in: text)
        var stack = [tree.rootNode]
        while let node = stack.popLast() {
            guard node.byteRange.contains(byteOffset) else { continue }
            if node.parent?.type == "block" { return node }
            for index in (0..<node.namedChildCount).reversed() {
                stack.append(node.namedChild(at: index)!)
            }
        }
        return nil
    }

    private static func surroundWithTryCatch(_ statement: SyntaxNode, thrown: String, in text: String, tree: JavaSyntaxTree) -> CodeAction {
        let ns = text as NSString
        let start = JavaImportInserter.textPosition(forByteOffset: statement.byteRange.lowerBound, in: tree.sourceBytes)
        let end = JavaImportInserter.textPosition(forByteOffset: statement.byteRange.upperBound, in: tree.sourceBytes)
        let statementIndent = indent(ofLineContaining: statement.byteRange.lowerBound, in: tree, text: text)
        let innerIndent = statementIndent + "    "
        let statementText = ns.substring(with: NSRange(
            location: start.utf16Offset, length: end.utf16Offset - start.utf16Offset))
        let lines = statementText.components(separatedBy: "\n")
        let reindented = ([innerIndent + (lines.first ?? "")] + lines.dropFirst().map { $0.isEmpty ? $0 : "    " + $0 })
            .joined(separator: "\n")
        let replacement = "try {\n\(reindented)\n\(statementIndent)} catch (\(thrown) e) {\n\(innerIndent)e.printStackTrace();\n\(statementIndent)}"
        return CodeAction(
            title: "Surround with try/catch", kind: "quickfix",
            edits: [TextEdit(
                range: TextRange(
                    start: TextPosition(line: start.line, column: start.column, utf16Offset: start.utf16Offset),
                    end: TextPosition(line: end.line, column: end.column, utf16Offset: end.utf16Offset)),
                replacement: replacement
            )]
        )
    }

    /// The leading whitespace of the line containing the byte offset.
    private static func indent(ofLineContaining byteOffset: Int, in tree: JavaSyntaxTree, text: String) -> String {
        let utf16 = JavaImportInserter.textPosition(forByteOffset: byteOffset, in: tree.sourceBytes).utf16Offset
        let ns = text as NSString
        var start = utf16
        while start > 0 {
            let previous = ns.substring(with: NSRange(location: start - 1, length: 1))
            if previous == "\n" { break }
            start -= 1
        }
        var indent = ""
        while start < ns.length {
            let char = ns.substring(with: NSRange(location: start, length: 1))
            guard char == " " || char == "\t" else { break }
            indent += char
            start += 1
        }
        return indent
    }
}
