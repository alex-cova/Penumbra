import EditorIntelligence
import Foundation

/// IntelliJ's default patterns: `[A-Z][A-Za-z\d]*`, `[a-z][A-Za-z\d]*` and `[A-Z][A-Z_\d]*`.
enum JavaNameShape {
    static func isUpperCamel(_ name: String) -> Bool {
        guard let first = name.first, first.isUppercase else { return false }
        return name.dropFirst().allSatisfy { $0.isLetter || $0.isNumber }
    }

    static func isLowerCamel(_ name: String) -> Bool {
        guard let first = name.first, first.isLowercase else { return false }
        return name.dropFirst().allSatisfy { $0.isLetter || $0.isNumber }
    }

    static func isConstantStyle(_ name: String) -> Bool {
        guard let first = name.first, first.isUppercase else { return false }
        return name.dropFirst().allSatisfy { $0.isUppercase || $0.isNumber || $0 == "_" }
    }

    /// Names with `$` come from generators, and `_` alone is the unnamed variable.
    static func isCheckable(_ name: String) -> Bool { !name.contains("$") && name != "_" }

    /// The words of a declaration's `modifiers` (`public`, `static`, `@Override`, …).
    static func modifierWords(of declaration: SyntaxNode) -> Set<String> {
        guard let modifiers = declaration.firstNamedChild(ofType: "modifiers") else { return [] }
        return Set(modifiers.text.split(whereSeparator: { !$0.isLetter && $0 != "@" }).map(String.init))
    }
}

enum JavaClassNamingInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.classNamingConvention
    static let nodeTypes: Set<String> = [
        "class_declaration", "interface_declaration", "enum_declaration", "record_declaration", "annotation_type_declaration",
    ]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let name = node.child(byFieldName: "name"), JavaNameShape.isCheckable(name.text), !JavaNameShape.isUpperCamel(name.text) else { return }
        report(JavaInspectionSupport.inspection(rule, message: "Name '\(name.text)' does not match the class naming convention 'UpperCamelCase'", node: name))
    }
}

enum JavaMethodNamingInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.methodNamingConvention
    static let nodeTypes: Set<String> = ["method_declaration"]
    private static let exempt: Set<String> = ["@Override", "@Test", "@ParameterizedTest", "@RepeatedTest", "@TestFactory", "@Native"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let name = node.child(byFieldName: "name"), JavaNameShape.isCheckable(name.text), !JavaNameShape.isLowerCamel(name.text),
              JavaNameShape.modifierWords(of: node).isDisjoint(with: exempt) else { return }
        // `Widget()` in class `Widget` is `method-name-same-as-class`'s to report.
        guard node.parent?.parent?.child(byFieldName: "name")?.text != name.text else { return }
        report(JavaInspectionSupport.inspection(rule, message: "Method name '\(name.text)' does not match 'lowerCamelCase'", node: name))
    }
}

enum JavaFieldNamingInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.fieldNamingConvention
    static let nodeTypes: Set<String> = ["field_declaration", "constant_declaration"]
    private static let serialization: Set<String> = ["serialVersionUID", "serialPersistentFields"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        let words = JavaNameShape.modifierWords(of: node)
        let isConstant = node.type == "constant_declaration" || (words.contains("static") && words.contains("final"))
        // A `static final Logger log` is a handle, not a constant, and is conventionally lower-case.
        if isConstant, let type = node.child(byFieldName: "type"), JavaDeclaredTypes.simpleName(of: type).hasSuffix("Logger") { return }
        for declarator in node.namedChildren(ofType: "variable_declarator") {
            guard let name = declarator.child(byFieldName: "name"), JavaNameShape.isCheckable(name.text),
                  !serialization.contains(name.text) else { continue }
            if isConstant {
                guard !JavaNameShape.isConstantStyle(name.text) else { continue }
                report(JavaInspectionSupport.inspection(rule, message: "Constant '\(name.text)' does not match 'UPPER_SNAKE_CASE'", node: name))
            } else if !JavaNameShape.isLowerCamel(name.text), !JavaNameShape.isConstantStyle(name.text) {
                // UPPER_CASE on a non-constant is `non-constant-field-named-like-constant`'s to report.
                report(JavaInspectionSupport.inspection(rule, message: "Field name '\(name.text)' does not match 'lowerCamelCase'", node: name))
            }
        }
    }
}

enum JavaLocalVariableNamingInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.localVariableNamingConvention
    static let nodeTypes: Set<String> = ["local_variable_declaration", "enhanced_for_statement", "resource"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        var names: [SyntaxNode] = []
        if node.type == "local_variable_declaration" {
            names = node.namedChildren(ofType: "variable_declarator").compactMap { $0.child(byFieldName: "name") }
        } else if let name = node.child(byFieldName: "name") {
            names = [name]
        }
        // A `final` local in constant style (`final int PRIME = 31;`) is a constant, not a misnamed variable.
        let isFinal = node.type == "local_variable_declaration" && JavaNameShape.modifierWords(of: node).contains("final")
        for name in names where JavaNameShape.isCheckable(name.text) && !JavaNameShape.isLowerCamel(name.text) {
            if isFinal, JavaNameShape.isConstantStyle(name.text) { continue }
            report(JavaInspectionSupport.inspection(rule, message: "Local variable name '\(name.text)' does not match 'lowerCamelCase'", node: name))
        }
    }
}

enum JavaParameterNamingInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.parameterNamingConvention
    static let nodeTypes: Set<String> = ["formal_parameter", "spread_parameter"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        let name = node.type == "formal_parameter"
            ? node.child(byFieldName: "name")
            : node.firstNamedChild(ofType: "variable_declarator")?.child(byFieldName: "name")
        // A record's components are named like fields, and `catch` parameters are a different node.
        guard let name, node.parent?.parent?.type != "record_declaration",
              JavaNameShape.isCheckable(name.text), !JavaNameShape.isLowerCamel(name.text) else { return }
        report(JavaInspectionSupport.inspection(rule, message: "Parameter name '\(name.text)' does not match 'lowerCamelCase'", node: name))
    }
}

enum JavaTypeParameterNamingInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.typeParameterNamingConvention
    static let nodeTypes: Set<String> = ["type_parameter"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let name = node.firstNamedChild(ofType: "type_identifier"), JavaNameShape.isCheckable(name.text),
              !JavaNameShape.isUpperCamel(name.text) else { return }
        report(JavaInspectionSupport.inspection(rule, message: "Type parameter name '\(name.text)' must start with an upper-case letter", node: name))
    }
}

enum JavaEnumConstantNamingInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.enumConstantNamingConvention
    static let nodeTypes: Set<String> = ["enum_constant"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let name = node.child(byFieldName: "name"), JavaNameShape.isCheckable(name.text),
              !JavaNameShape.isConstantStyle(name.text) else { return }
        report(JavaInspectionSupport.inspection(rule, message: "Enum constant '\(name.text)' does not match 'UPPER_SNAKE_CASE'", node: name))
    }
}

enum JavaNonConstantFieldNamedLikeConstantInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.nonConstantFieldNamedLikeConstant
    static let nodeTypes: Set<String> = ["field_declaration"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        let words = JavaNameShape.modifierWords(of: node)
        guard !(words.contains("static") && words.contains("final")) else { return }
        for declarator in node.namedChildren(ofType: "variable_declarator") {
            // A single letter such as `N` or `T` is as likely a short name as a constant.
            guard let name = declarator.child(byFieldName: "name"), name.text.count > 1, JavaNameShape.isConstantStyle(name.text) else { continue }
            report(JavaInspectionSupport.inspection(
                rule, message: "Field '\(name.text)' is named like a constant but is not 'static final'", node: name
            ))
        }
    }
}

enum JavaMethodNameSameAsClassInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.methodNameSameAsClass
    static let nodeTypes: Set<String> = ["method_declaration"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let name = node.child(byFieldName: "name"), let owner = node.parent?.parent,
              JavaTypeMembers.typeDeclarations.contains(owner.type) || owner.type == "interface_declaration",
              owner.child(byFieldName: "name")?.text == name.text else { return }
        report(JavaInspectionSupport.inspection(rule, message: "Method '\(name.text)' has the name of its class; a constructor has no return type", node: name))
    }
}
