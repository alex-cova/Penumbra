import Foundation
import SwiftSyntax

/// Write the type of `let x = value` when the value says it by itself: a string, boolean or collection literal,
/// or a call of a type (`Foo(…)`, `Outer.Inner(…)`, `Foo<Int>(…)`). Anything whose type the compiler infers from
/// context or from another declaration (a number literal that may become a `Double`, a function's result, an
/// implicit member) is left alone, because a guessed type could be wrong.
public enum SwiftAddExplicitType {
    public static func edits(in text: String, caret: Int) -> SwiftRefactoringResult {
        guard let file = SwiftRefactoringFile.load(text) else {
            return .failure(.init("The file has syntax errors; fix them before refactoring."))
        }
        guard let binding = binding(at: caret, file: file) else {
            return .failure(.init("Place the caret on the name in a `let` or `var` declaration."))
        }
        guard binding.typeAnnotation == nil, let initializer = binding.initializer?.value else {
            return .failure(.init("The declaration already has a type, or has no value to take it from."))
        }
        guard binding.pattern.is(IdentifierPatternSyntax.self) else {
            return .failure(.init("Only a single name can be given a type."))
        }
        guard let type = type(of: initializer) else {
            return .failure(.init("The type cannot be told from the value alone."))
        }
        let name = SwiftRefactoringFile.trimmed(binding.pattern)
        return .success([SwiftTextEdit(bytes: name.upperBound ..< name.upperBound, replacement: ": \(type)")])
    }

    public static func isAvailable(in text: String, caret: Int) -> Bool {
        if case .success = edits(in: text, caret: caret) { return true }
        return false
    }

    private static func binding(at caret: Int, file: SwiftRefactoringFile) -> PatternBindingSyntax? {
        guard let token = file.tree.token(at: AbsolutePosition(utf8Offset: min(max(caret, 0), max(file.utf8.count - 1, 0)))) else { return nil }
        var node: Syntax? = Syntax(token)
        while let current = node {
            if let binding = current.as(PatternBindingSyntax.self) {
                let name = SwiftRefactoringFile.trimmed(binding.pattern)
                return name.contains(caret) || name.upperBound == caret ? binding : nil
            }
            if current.is(CodeBlockItemSyntax.self) || current.is(MemberBlockItemSyntax.self) { return nil }
            node = current.parent
        }
        return nil
    }

    /// The type of an expression that names it, or nil.
    static func type(of expression: ExprSyntax) -> String? {
        if expression.is(StringLiteralExprSyntax.self) { return "String" }
        if expression.is(BooleanLiteralExprSyntax.self) { return "Bool" }
        if let array = expression.as(ArrayExprSyntax.self) {
            let types = Set(array.elements.compactMap { literalType($0.expression) })
            guard types.count == 1, array.elements.allSatisfy({ literalType($0.expression) != nil }), let element = types.first else { return nil }
            return "[\(element)]"
        }
        if let dictionary = expression.as(DictionaryExprSyntax.self), case .elements(let elements) = dictionary.content {
            let keys = Set(elements.compactMap { literalType($0.key) })
            let values = Set(elements.compactMap { literalType($0.value) })
            guard keys.count == 1, values.count == 1, elements.allSatisfy({ literalType($0.key) != nil && literalType($0.value) != nil }),
                  let key = keys.first, let value = values.first else { return nil }
            return "[\(key): \(value)]"
        }
        if let tried = expression.as(TryExprSyntax.self) {
            guard let inner = type(of: tried.expression) else { return nil }
            return tried.questionOrExclamationMark?.tokenKind == .postfixQuestionMark ? "\(inner)?" : (tried.questionOrExclamationMark == nil ? inner : nil)
        }
        if let awaited = expression.as(AwaitExprSyntax.self) { return type(of: awaited.expression) }
        if let call = expression.as(FunctionCallExprSyntax.self) { return constructedType(call.calledExpression) }
        return nil
    }

    /// Only the literals whose type is fixed: a number could become a `Double` by context.
    private static func literalType(_ expression: ExprSyntax) -> String? {
        if expression.is(StringLiteralExprSyntax.self) { return "String" }
        if expression.is(BooleanLiteralExprSyntax.self) { return "Bool" }
        return nil
    }

    /// `Foo`, `Outer.Inner`, `Foo<Int>`, `Foo.init` read as a type name; a lower-case call is a function.
    private static func constructedType(_ callee: ExprSyntax) -> String? {
        if let specialization = callee.as(GenericSpecializationExprSyntax.self) {
            guard let base = constructedType(specialization.expression) else { return nil }
            return base + specialization.genericArgumentClause.trimmedDescription
        }
        if let reference = callee.as(DeclReferenceExprSyntax.self) {
            let name = reference.baseName.text
            guard name.first?.isUppercase == true, reference.argumentNames == nil else { return nil }
            return name
        }
        if let access = callee.as(MemberAccessExprSyntax.self), let base = access.base {
            let member = access.declName.baseName.text
            if member == "init" { return constructedType(base) }
            guard member.first?.isUppercase == true, let owner = constructedType(base) else { return nil }
            return "\(owner).\(member)"
        }
        return nil
    }
}
