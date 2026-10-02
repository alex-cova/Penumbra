import EditorIntelligence
import Foundation

/// The Javadoc comment right above a declaration, split into the tags the inspections check.
struct JavaJavadoc {
    let comment: SyntaxNode
    /// Names after `@param`, type parameters spelled `<T>`.
    let paramTags: [String]
    let hasReturnTag: Bool
    /// Only `{@inheritDoc}`-style comments are exempt: the real text lives in the overridden method.
    let inherits: Bool

    /// The `/** … */` comment that is the declaration's immediate previous sibling.
    static func above(_ declaration: SyntaxNode) -> JavaJavadoc? {
        guard let comment = declaration.previousNamedSibling, comment.type == "block_comment", comment.text.hasPrefix("/**") else { return nil }
        var params: [String] = []
        var hasReturn = false
        for rawLine in comment.text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("/**") { line.removeFirst(3) }
            while line.hasPrefix("*"), !line.hasPrefix("*/") { line.removeFirst() }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("@param") {
                let rest = line.dropFirst("@param".count).trimmingCharacters(in: .whitespaces)
                if let name = rest.split(whereSeparator: { $0.isWhitespace || $0 == "*" }).first { params.append(String(name)) }
            } else if line.hasPrefix("@return") {
                hasReturn = true
            }
        }
        return JavaJavadoc(comment: comment, paramTags: params, hasReturnTag: hasReturn, inherits: comment.text.contains("{@inheritDoc}"))
    }

    /// An edit that adds `tag` as a new line above the comment's closing `*/`; nil for a one-line comment.
    func insertion(of tag: String, in tree: JavaSyntaxTree) -> TextEdit? {
        let bytes = tree.sourceBytes
        let closing = comment.endByte - 2
        guard closing > comment.startByte, bytes[closing] == UInt8(ascii: "*"), bytes[closing + 1] == UInt8(ascii: "/") else { return nil }
        let lineStart = JavaSourceBytes.lineStart(before: closing, in: bytes)
        guard lineStart > comment.startByte else { return nil }
        let indent = JavaSourceBytes.leadingWhitespace(ofLineContaining: closing, in: bytes)
        // Only a line that is nothing but `*/` can take a new line above it.
        guard lineStart + indent.utf8.count == closing else { return nil }
        return JavaInspectionSupport.edit(replacingBytes: lineStart..<lineStart, with: "\(indent)* \(tag)\n", in: tree)
    }
}

private enum JavaJavadocSupport {
    /// The method or constructor a node of a diagnostic belongs to.
    static func declaration(of node: SyntaxNode) -> SyntaxNode? {
        var current: SyntaxNode? = node
        while let candidate = current {
            if candidate.type == "method_declaration" || candidate.type == "constructor_declaration" { return candidate }
            current = candidate.parent
        }
        return nil
    }

    static func parameterNames(of declaration: SyntaxNode) -> [SyntaxNode] {
        declaration.child(byFieldName: "parameters")?.namedChildren
            .filter { $0.type == "formal_parameter" || $0.type == "spread_parameter" }
            .compactMap { parameter in
                parameter.child(byFieldName: "name") ?? parameter.namedChildren(ofType: "variable_declarator").first?.child(byFieldName: "name")
            } ?? []
    }

    static func typeParameterNames(of declaration: SyntaxNode) -> [SyntaxNode] {
        declaration.firstNamedChild(ofType: "type_parameters")?.namedChildren(ofType: "type_parameter")
            .compactMap { $0.firstNamedChild(ofType: "type_identifier") } ?? []
    }

    static func missingParamTag(for name: SyntaxNode, in declaration: SyntaxNode) -> (tag: String, javadoc: JavaJavadoc)? {
        guard let javadoc = JavaJavadoc.above(declaration), !javadoc.inherits else { return nil }
        let isType = name.type == "type_identifier"
        let tagName = isType ? "<\(name.text)>" : name.text
        return javadoc.paramTags.contains(tagName) ? nil : ("@param \(tagName)", javadoc)
    }
}

enum JavaJavadocMissingParamInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.javadocMissingParam
    static let nodeTypes: Set<String> = ["method_declaration", "constructor_declaration"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        for name in JavaJavadocSupport.typeParameterNames(of: node) + JavaJavadocSupport.parameterNames(of: node) {
            guard let (tag, javadoc) = JavaJavadocSupport.missingParamTag(for: name, in: node) else { continue }
            let label = name.type == "type_identifier" ? "type parameter '<\(name.text)>'" : "parameter '\(name.text)'"
            let canFix = javadoc.insertion(of: tag, in: node.tree) != nil
            report(JavaInspectionSupport.inspection(rule, message: "Missing '@param' tag for \(label)", node: name, fixTitle: canFix ? "Add '\(tag)'" : nil))
        }
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        for type in ["identifier", "type_identifier"] {
            guard let name = JavaInspectionSupport.node(of: type, for: diagnostic, tree: tree, source: source),
                  let declaration = JavaJavadocSupport.declaration(of: name),
                  let (tag, javadoc) = JavaJavadocSupport.missingParamTag(for: name, in: declaration),
                  let edit = javadoc.insertion(of: tag, in: tree) else { continue }
            return [CodeAction(title: "Add '\(tag)'", kind: "quickfix", edits: [edit], isPreferred: true)]
        }
        return []
    }
}

enum JavaJavadocMissingReturnInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.javadocMissingReturn
    static let nodeTypes: Set<String> = ["method_declaration"]

    private static func missing(in node: SyntaxNode) -> (type: SyntaxNode, javadoc: JavaJavadoc)? {
        guard let type = node.child(byFieldName: "type"), type.type != "void_type", let javadoc = JavaJavadoc.above(node),
              !javadoc.inherits, !javadoc.hasReturnTag else { return nil }
        return (type, javadoc)
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let (type, javadoc) = missing(in: node) else { return }
        let canFix = javadoc.insertion(of: "@return", in: node.tree) != nil
        report(JavaInspectionSupport.inspection(rule, message: "Missing '@return' tag", node: type, fixTitle: canFix ? "Add '@return'" : nil))
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        let range = ProblemLocator.nsRange(for: diagnostic.range, in: source)
        let start = JavaNavigationText.utf8ByteOffset(forUTF16Offset: range.location, in: source)
        var current: SyntaxNode? = tree.node(atByteOffset: start)
        while let node = current, node.type != "method_declaration" { current = node.parent }
        guard let method = current, let (_, javadoc) = missing(in: method), let edit = javadoc.insertion(of: "@return", in: tree) else { return [] }
        return [CodeAction(title: "Add '@return'", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

enum JavaJavadocInvalidParamInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.javadocInvalidParam
    static let nodeTypes: Set<String> = ["method_declaration", "constructor_declaration"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let javadoc = JavaJavadoc.above(node) else { return }
        var known = Set(JavaJavadocSupport.parameterNames(of: node).map(\.text))
        known.formUnion(JavaJavadocSupport.typeParameterNames(of: node).map { "<\($0.text)>" })
        var seen = Set<String>()
        for tag in javadoc.paramTags {
            if !known.contains(tag) {
                report(JavaInspectionSupport.inspection(rule, message: "'@param \(tag)' does not match a parameter", node: javadoc.comment))
            } else if !seen.insert(tag).inserted {
                report(JavaInspectionSupport.inspection(rule, message: "Duplicate '@param \(tag)' tag", node: javadoc.comment))
            }
        }
    }
}
