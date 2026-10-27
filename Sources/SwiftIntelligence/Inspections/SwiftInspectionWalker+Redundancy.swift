import Foundation
import SwiftSyntax

// Redundant code: something written that the language already implies.
extension SwiftInspectionWalker {
    /// `{ return x }` as the whole body of a function, accessor or closure. Not when `x` is an `if` or
    /// `switch` expression: dropping `return` there needs Swift 5.9, and this file may build with less.
    func checkRedundantReturn(_ node: ReturnStmtSyntax) {
        guard isOn(.redundantReturn), let expression = node.expression,
              !expression.is(IfExprSyntax.self), !expression.is(SwitchExprSyntax.self),
              let item = node.parent?.as(CodeBlockItemSyntax.self),
              let list = item.parent?.as(CodeBlockItemListSyntax.self), list.count == 1,
              let owner = list.parent, isSingleExpressionBody(owner) else { return }
        let removal = bytes(node.returnKeyword).lowerBound ..< bytes(expression).lowerBound
        report(
            .redundantReturn, "`return` is implied when the body is a single expression.", at: node.returnKeyword,
            fixes: [fix("Remove 'return'", edit(removal, ""))]
        )
    }

    private func isSingleExpressionBody(_ owner: Syntax) -> Bool {
        if owner.is(ClosureExprSyntax.self) || owner.is(AccessorBlockSyntax.self) { return true }
        guard let block = owner.as(CodeBlockSyntax.self), let parent = block.parent else { return false }
        return parent.is(FunctionDeclSyntax.self) || parent.is(AccessorDeclSyntax.self)
    }

    /// `if (x) {`: the parentheses around the whole condition. Not when the condition holds a closure, where
    /// they keep a trailing closure from being read as the body.
    func checkRedundantParentheses(in conditions: ConditionElementListSyntax) {
        guard isOn(.redundantParentheses) else { return }
        for element in conditions {
            if case .expression(let expression) = element.condition { checkRedundantParentheses(around: expression) }
        }
    }

    func checkRedundantParentheses(around expression: ExprSyntax) {
        guard isOn(.redundantParentheses), let tuple = expression.as(TupleExprSyntax.self),
              tuple.elements.count == 1, let element = tuple.elements.first,
              element.label == nil, element.trailingComma == nil, !containsClosure(element.expression) else { return }
        report(
            .redundantParentheses, "The parentheses around this condition are not needed.", at: tuple,
            fixes: [fix("Remove parentheses", edit(bytes(tuple.leftParen), ""), edit(bytes(tuple.rightParen), ""))]
        )
    }

    /// `var x: Int? = nil`. A `let` needs its value, a `lazy` or wrapped property needs its initializer, so
    /// those are left alone.
    func checkRedundantOptionalInitialization(_ node: VariableDeclSyntax) {
        guard isOn(.redundantOptionalInitialization), node.bindingSpecifier.tokenKind == .keyword(.var), node.attributes.isEmpty else { return }
        for modifier in node.modifiers where modifier.name.tokenKind == .keyword(.lazy) { return }
        for binding in node.bindings {
            guard binding.pattern.is(IdentifierPatternSyntax.self), let annotation = binding.typeAnnotation,
                  annotation.type.is(OptionalTypeSyntax.self), let initializer = binding.initializer,
                  initializer.value.is(NilLiteralExprSyntax.self) else { continue }
            let removal = bytes(annotation).upperBound ..< bytes(initializer).upperBound
            report(
                .redundantOptionalInitialization, "An optional variable starts as nil; `= nil` is redundant.", at: initializer,
                fixes: [fix("Remove '= nil'", edit(removal, ""))]
            )
        }
    }

    /// `func f() -> Void` and `-> ()`.
    func checkRedundantVoidReturn(_ node: FunctionDeclSyntax) {
        guard isOn(.redundantVoidReturn), let clause = node.signature.returnClause else { return }
        let type = clause.type
        let isVoid = (type.as(IdentifierTypeSyntax.self).map { $0.name.text == "Void" && $0.genericArgumentClause == nil } ?? false)
            || (type.as(TupleTypeSyntax.self)?.elements.isEmpty ?? false)
        guard isVoid, let previous = clause.previousToken(viewMode: .sourceAccurate) else { return }
        let removal = bytes(previous).upperBound ..< bytes(clause).upperBound
        report(
            .redundantVoidReturn, "A function returns Void by default; `-> \(type.trimmedDescription)` is redundant.", at: clause,
            fixes: [fix("Remove return type", edit(removal, ""))]
        )
    }

    /// A trailing `break` after other statements in a `case`: Swift does not fall through. A `case` whose only
    /// statement is `break` is how an empty case is written, and stays.
    func checkUnneededBreak(_ node: SwitchCaseSyntax) {
        guard isOn(.unneededBreak), node.statements.count >= 2, let last = node.statements.last,
              let statement = last.item.as(BreakStmtSyntax.self), statement.label == nil else { return }
        let previous = node.statements[node.statements.index(before: node.statements.index(before: node.statements.endIndex))]
        let removal = bytes(previous).upperBound ..< bytes(last).upperBound
        report(
            .unneededBreak, "A `case` does not fall through, so this `break` does nothing.", at: statement,
            fixes: [fix("Remove 'break'", edit(removal, ""))]
        )
    }

    /// A named closure parameter the body never mentions. Any identifier of that name in the body counts as a
    /// use, even a member after a dot: that can hide an unused parameter but never reports a used one.
    func checkUnusedClosureParameters(_ node: ClosureExprSyntax) {
        guard isOn(.unusedClosureParameter), let parameters = node.signature?.parameterClause else { return }
        var names: [TokenSyntax] = []
        switch parameters {
        case .simpleInput(let list):
            names = list.map(\.name)
        case .parameterClause(let clause):
            names = clause.parameters.map { $0.secondName ?? $0.firstName }
        }
        names.removeAll { $0.text == "_" }
        guard !names.isEmpty else { return }
        let referenced = IdentifierCollector()
        referenced.walk(node.statements)
        for name in names where !referenced.names.contains(name.text) {
            report(
                .unusedClosureParameter, "The parameter `\(name.text)` is never used.", at: name,
                fixes: [fix("Replace '\(name.text)' with '_'", edit(bytes(name), "_"))]
            )
        }
    }

    /// `if x {}` with nothing inside, not even a comment. A `for` or `while` with an empty body is how a
    /// sequence is drained (`for await _ in stream {}`, `while it.next() != nil {}`) and is not reported.
    func checkEmptyBody(_ body: CodeBlockSyntax, keyword: TokenSyntax) {
        guard isOn(.emptyStatementBody), body.statements.isEmpty, !hasComment(in: body) else { return }
        report(.emptyStatementBody, "This `\(keyword.text)` has an empty body.", at: keyword)
    }

    /// `Foo.init(…)` is `Foo(…)`. Only a call on a type-looking name (`Foo`, `Outer.Inner`) is judged:
    /// `super.init` and `self.init` are not.
    func checkExplicitInit(_ node: FunctionCallExprSyntax) {
        guard isOn(.explicitInit), let member = node.calledExpression.as(MemberAccessExprSyntax.self),
              member.declName.baseName.text == "init", member.declName.argumentNames == nil,
              let base = member.base, looksLikeTypeName(base) else { return }
        let removal = bytes(base).upperBound ..< bytes(member.declName).upperBound
        report(
            .explicitInit, "`.init` is implied when calling a type.", at: member.declName,
            fixes: [fix("Remove '.init'", edit(removal, ""))]
        )
    }

    private func looksLikeTypeName(_ expr: ExprSyntax) -> Bool {
        if let reference = expr.as(DeclReferenceExprSyntax.self) {
            return reference.baseName.text.first?.isUppercase == true
        }
        if let member = expr.as(MemberAccessExprSyntax.self), let base = member.base {
            return member.declName.baseName.text.first?.isUppercase == true && looksLikeTypeName(base)
        }
        return false
    }
}

/// Every identifier that appears as an expression or a type name below a node.
private final class IdentifierCollector: SyntaxVisitor {
    var names: Set<String> = []

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.baseName.text)
        return .visitChildren
    }

    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.name.text)
        return .visitChildren
    }
}
