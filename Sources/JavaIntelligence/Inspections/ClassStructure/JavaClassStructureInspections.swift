import EditorIntelligence
import Foundation

/// Shared reading of class declarations for the class-structure rules.
enum JavaClassShape {
    static let comments: Set<String> = ["line_comment", "block_comment"]

    /// The members of a class, record or interface body, comments left out.
    static func members(of declaration: SyntaxNode) -> [SyntaxNode] {
        guard let body = declaration.child(byFieldName: "body") else { return [] }
        return body.namedChildren.filter { !comments.contains($0.type) }
    }

    /// Simple names of the interfaces in an `implements` clause.
    static func implementedNames(of declaration: SyntaxNode) -> Set<String> {
        guard let clause = declaration.child(byFieldName: "interfaces") else { return [] }
        var names: Set<String> = []
        for list in clause.namedChildren(ofType: "type_list") {
            for type in list.namedChildren { names.insert(JavaDeclaredTypes.simpleName(of: type)) }
        }
        return names
    }

    static func hasAnnotation(_ declaration: SyntaxNode) -> Bool {
        declaration.firstNamedChild(ofType: "modifiers")?.text.contains("@") ?? false
    }

    /// The keyword token `word` in the declaration's `modifiers`.
    static func modifierToken(_ word: String, in declaration: SyntaxNode) -> SyntaxNode? {
        declaration.firstNamedChild(ofType: "modifiers")?.children.first { $0.type == word }
    }

    /// Leading whitespace of the line `node` starts on.
    static func indent(of node: SyntaxNode, tree: JavaSyntaxTree) -> String {
        JavaSourceBytes.leadingWhitespace(ofLineContaining: node.startByte, in: tree.sourceBytes)
    }

    /// An edit that deletes the token and the spaces after it.
    static func removal(of token: SyntaxNode, in tree: JavaSyntaxTree) -> TextEdit {
        let bytes = tree.sourceBytes
        var end = token.endByte
        while end < bytes.count, bytes[end] == 0x20 || bytes[end] == 0x09 { end += 1 }
        return JavaInspectionSupport.edit(replacingBytes: token.startByte..<end, with: "", in: tree)
    }

    /// The declaration that owns the identifier a diagnostic was reported on.
    static func declaration(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> SyntaxNode? {
        guard let name = JavaInspectionSupport.node(of: "identifier", for: diagnostic, tree: tree, source: source),
              var owner = name.parent else { return nil }
        if owner.type == "variable_declarator", let outer = owner.parent { owner = outer }
        return owner
    }

    /// An edit that inserts `text` right after the `{` of the declaration's body.
    static func insertAfterBrace(of declaration: SyntaxNode, text: String, in tree: JavaSyntaxTree) -> TextEdit? {
        guard let body = declaration.child(byFieldName: "body") else { return nil }
        let at = body.startByte + 1
        return JavaInspectionSupport.edit(replacingBytes: at..<at, with: text, in: tree)
    }

    /// Indent for a new first member: that of the existing first member, else one level deeper than the declaration.
    static func memberIndent(of declaration: SyntaxNode, tree: JavaSyntaxTree) -> String {
        if let first = members(of: declaration).first { return indent(of: first, tree: tree) }
        return indent(of: declaration, tree: tree) + "    "
    }
}

enum JavaUtilityClassConstructorInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.utilityClassWithPublicConstructor
    static let nodeTypes: Set<String> = ["class_declaration"]

    /// A class with no superclass or interfaces whose members are all static.
    private static func isUtilityClass(_ node: SyntaxNode) -> Bool {
        let words = JavaNameShape.modifierWords(of: node)
        guard !words.contains("abstract"), !JavaClassShape.hasAnnotation(node), node.child(byFieldName: "superclass") == nil,
              node.child(byFieldName: "interfaces") == nil else { return false }
        var methods: [String] = []
        var fields = 0
        for member in JavaClassShape.members(of: node) {
            switch member.type {
            case "constructor_declaration", "static_initializer", "interface_declaration", "enum_declaration", "record_declaration",
                 "annotation_type_declaration":
                continue
            case "method_declaration":
                guard JavaNameShape.modifierWords(of: member).contains("static") else { return false }
                methods.append(member.child(byFieldName: "name")?.text ?? "")
            case "field_declaration":
                guard JavaNameShape.modifierWords(of: member).contains("static") else { return false }
                fields += 1
            case "class_declaration":
                guard JavaNameShape.modifierWords(of: member).contains("static") else { return false }
            default:
                return false
            }
        }
        if fields == 0 && methods.isEmpty { return false }
        // A class that only holds `main` is an entry point, not a utility class.
        return !(fields == 0 && methods == ["main"])
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard isUtilityClass(node), let name = node.child(byFieldName: "name") else { return }
        let constructors = JavaClassShape.members(of: node).filter { $0.type == "constructor_declaration" }
        if constructors.isEmpty {
            guard JavaNameShape.modifierWords(of: node).contains("public") else { return }
            report(JavaInspectionSupport.inspection(
                rule, message: "Utility class '\(name.text)' has an implicit public constructor", node: name,
                fixTitle: "Add a private constructor"
            ))
            return
        }
        for constructor in constructors where JavaNameShape.modifierWords(of: constructor).contains("public") {
            guard let constructorName = constructor.child(byFieldName: "name") else { continue }
            report(JavaInspectionSupport.inspection(
                rule, message: "Utility class '\(name.text)' has a public constructor", node: constructorName,
                fixTitle: "Make the constructor private"
            ))
        }
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let owner = JavaClassShape.declaration(for: diagnostic, tree: tree, source: source) else { return [] }
        if owner.type == "constructor_declaration", let token = JavaClassShape.modifierToken("public", in: owner) {
            let edit = JavaInspectionSupport.edit(replacingBytes: token.byteRange, with: "private", in: tree)
            return [CodeAction(title: "Make the constructor private", kind: "quickfix", edits: [edit], isPreferred: true)]
        }
        guard owner.type == "class_declaration", let name = owner.child(byFieldName: "name") else { return [] }
        let indent = JavaClassShape.memberIndent(of: owner, tree: tree)
        let text = "\n\(indent)private \(name.text)() {\n\(indent)}\n"
        guard let edit = JavaClassShape.insertAfterBrace(of: owner, text: text, in: tree) else { return [] }
        return [CodeAction(title: "Add a private constructor", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

enum JavaPublicFieldInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.publicField
    static let nodeTypes: Set<String> = ["field_declaration"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        let words = JavaNameShape.modifierWords(of: node)
        guard words.contains("public"), !words.contains("final"), !JavaClassShape.hasAnnotation(node),
              node.parent?.parent?.type == "class_declaration" else { return }
        for declarator in node.namedChildren(ofType: "variable_declarator") {
            guard let name = declarator.child(byFieldName: "name") else { continue }
            report(JavaInspectionSupport.inspection(rule, message: "Public field '\(name.text)' breaks encapsulation", node: name))
        }
    }
}

enum JavaMissingSerialVersionUIDInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.missingSerialVersionUID
    static let nodeTypes: Set<String> = ["class_declaration"]
    private static let serializable: Set<String> = ["Serializable", "Externalizable"]

    private static func needsUID(_ node: SyntaxNode) -> Bool {
        guard !JavaClassShape.implementedNames(of: node).isDisjoint(with: serializable) else { return false }
        for member in JavaClassShape.members(of: node) where member.type == "field_declaration" {
            if member.namedChildren(ofType: "variable_declarator").contains(where: { $0.child(byFieldName: "name")?.text == "serialVersionUID" }) {
                return false
            }
        }
        return true
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard needsUID(node), let name = node.child(byFieldName: "name") else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "Serializable class '\(name.text)' does not declare 'serialVersionUID'", node: name,
            fixTitle: "Add 'serialVersionUID'"
        ))
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let owner = JavaClassShape.declaration(for: diagnostic, tree: tree, source: source), owner.type == "class_declaration" else { return [] }
        let indent = JavaClassShape.memberIndent(of: owner, tree: tree)
        let text = "\n\(indent)private static final long serialVersionUID = 1L;\n"
        guard let edit = JavaClassShape.insertAfterBrace(of: owner, text: text, in: tree) else { return [] }
        return [CodeAction(title: "Add 'serialVersionUID'", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

enum JavaCloneWithoutCloneableInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.cloneWithoutCloneable
    static let nodeTypes: Set<String> = ["method_declaration"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let name = node.child(byFieldName: "name"), name.text == "clone", node.child(byFieldName: "parameters")?.namedChildCount == 0,
              let owner = node.parent?.parent, owner.type == "class_declaration",
              // A superclass may already be `Cloneable`.
              owner.child(byFieldName: "superclass") == nil, !JavaNameShape.modifierWords(of: owner).contains("abstract"),
              // An interface may itself extend `Cloneable`.
              JavaClassShape.implementedNames(of: owner).subtracting(["Serializable"]).isEmpty,
              // `native` and abstract declarations have no body; a body that only throws opts out of cloning on purpose.
              let body = node.child(byFieldName: "body"), !body.namedChildren.allSatisfy({ $0.type == "throw_statement" || JavaClassShape.comments.contains($0.type) }) else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "'clone()' is declared in '\(owner.child(byFieldName: "name")?.text ?? "")', which does not implement 'Cloneable'", node: name
        ))
    }
}

/// `final` members of a `final` class and `protected` members of a class that nothing can extend.
enum JavaFinalClassMembers {
    static let memberTypes: Set<String> = [
        "method_declaration", "field_declaration", "constructor_declaration", "class_declaration", "interface_declaration",
        "enum_declaration", "record_declaration",
    ]
    private static let overriddenWithoutAnnotation: Set<String> = ["clone", "finalize"]

    static func isFinal(_ node: SyntaxNode) -> Bool {
        node.type == "record_declaration" || JavaNameShape.modifierWords(of: node).contains("final")
    }

    /// The name node a member's diagnostic is reported on.
    static func nameNode(of member: SyntaxNode) -> SyntaxNode? {
        if member.type == "field_declaration" {
            return member.firstNamedChild(ofType: "variable_declarator")?.child(byFieldName: "name")
        }
        return member.child(byFieldName: "name")
    }

    static func members(of owner: SyntaxNode, with word: String) -> [SyntaxNode] {
        guard isFinal(owner) else { return [] }
        return JavaClassShape.members(of: owner).filter { member in
            guard memberTypes.contains(member.type) else { return false }
            return JavaNameShape.modifierWords(of: member).contains(word)
        }
    }

    static func removeModifier(_ word: String, diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String, title: String) -> [CodeAction] {
        guard let owner = JavaClassShape.declaration(for: diagnostic, tree: tree, source: source),
              let token = JavaClassShape.modifierToken(word, in: owner) else { return [] }
        return [CodeAction(title: title, kind: "quickfix", edits: [JavaClassShape.removal(of: token, in: tree)], isPreferred: true)]
    }

    /// Whether dropping `protected` could break an override: `@Override`, `clone`/`finalize`, or any method of a class with a supertype.
    static func isOverride(_ member: SyntaxNode, in owner: SyntaxNode) -> Bool {
        guard member.type == "method_declaration" else { return false }
        if JavaNameShape.modifierWords(of: member).contains("@Override") { return true }
        if overriddenWithoutAnnotation.contains(member.child(byFieldName: "name")?.text ?? "") { return true }
        return owner.child(byFieldName: "superclass") != nil || owner.child(byFieldName: "interfaces") != nil
    }
}

enum JavaFinalMethodInFinalClassInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.finalMethodInFinalClass
    static let nodeTypes: Set<String> = ["class_declaration", "record_declaration"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        for method in JavaFinalClassMembers.members(of: node, with: "final") where method.type == "method_declaration" {
            guard let name = method.child(byFieldName: "name") else { continue }
            report(JavaInspectionSupport.inspection(
                rule, message: "Method '\(name.text)' is declared 'final' in a final class", node: name, fixTitle: "Remove 'final'"
            ))
        }
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        JavaFinalClassMembers.removeModifier("final", diagnostic: diagnostic, tree: tree, source: source, title: "Remove 'final'")
    }
}

enum JavaProtectedMemberInFinalClassInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.protectedMemberInFinalClass
    static let nodeTypes: Set<String> = ["class_declaration", "record_declaration"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        for member in JavaFinalClassMembers.members(of: node, with: "protected") where !JavaFinalClassMembers.isOverride(member, in: node) {
            guard let name = JavaFinalClassMembers.nameNode(of: member) else { continue }
            report(JavaInspectionSupport.inspection(
                rule, message: "'\(name.text)' is declared 'protected' in a final class", node: name, fixTitle: "Remove 'protected'"
            ))
        }
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        JavaFinalClassMembers.removeModifier("protected", diagnostic: diagnostic, tree: tree, source: source, title: "Remove 'protected'")
    }
}

enum JavaClassMayBeInterfaceInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.classMayBeInterface
    static let nodeTypes: Set<String> = ["class_declaration"]
    private static let blocked: Set<String> = ["private", "protected", "static", "final", "synchronized", "native", "default"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let name = node.child(byFieldName: "name"), node.child(byFieldName: "superclass") == nil,
              !JavaClassShape.hasAnnotation(node), JavaNameShape.modifierWords(of: node).contains("abstract") else { return }
        var methods = 0
        for member in JavaClassShape.members(of: node) {
            let words = JavaNameShape.modifierWords(of: member)
            switch member.type {
            case "method_declaration":
                // Only abstract, public-or-package methods fit an interface; a body means `default`.
                guard member.child(byFieldName: "body") == nil, words.isDisjoint(with: blocked), !JavaClassShape.hasAnnotation(member) else { return }
                methods += 1
            case "field_declaration":
                guard words.contains("static"), words.contains("final"), words.isDisjoint(with: ["private", "protected"]) else { return }
            default:
                return
            }
        }
        guard methods > 0 else { return }
        report(JavaInspectionSupport.inspection(rule, message: "Abstract class '\(name.text)' may be an interface", node: name))
    }
}
