import Foundation
import SwiftSyntax

// Probable bugs: code that crashes, swallows an error or cannot do what it says.
extension SwiftInspectionWalker {
    func checkForceUnwrap(_ node: ForceUnwrapExprSyntax) {
        guard isOn(.forceUnwrap) else { return }
        report(.forceUnwrap, "Force unwrapping crashes if the value is nil; use `if let`, `guard let` or `??`.", at: node)
    }

    func checkForceTry(_ node: TryExprSyntax) {
        guard isOn(.forceTry), node.questionOrExclamationMark?.tokenKind == .exclamationMark else { return }
        let range = bytes(node.tryKeyword).lowerBound ..< bytes(node.questionOrExclamationMark!).upperBound
        report(.forceTry, "`try!` crashes if the call throws; use `do`/`catch` or `try?`.", range)
    }

    func checkForceCast(_ node: AsExprSyntax) {
        guard isOn(.forceCast), node.questionOrExclamationMark?.tokenKind == .exclamationMark else { return }
        let range = bytes(node.asKeyword).lowerBound ..< bytes(node.questionOrExclamationMark!).upperBound
        report(.forceCast, "`as!` crashes if the cast fails; use `as?`.", range)
    }

    func checkEmptyCatch(_ node: CatchClauseSyntax) {
        guard isOn(.emptyCatch), node.body.statements.isEmpty, !hasComment(in: node.body) else { return }
        report(.emptyCatch, "Empty `catch` swallows the error; handle it, or say in a comment why it can be ignored.", at: node.catchKeyword)
    }

    /// `a && a`, `x < x`, `n - n`: the second operand adds nothing, and the whole expression is a constant.
    /// `==` and `!=` are left out, because `x != x` is the idiom for a NaN test.
    func checkIdenticalOperands(_ node: InfixOperatorExprSyntax) {
        guard isOn(.identicalOperands), let op = operatorText(of: node),
              ["&&", "||", "<", ">", "<=", ">=", "-", "/", "%"].contains(op) else { return }
        guard isPure(node.leftOperand), node.leftOperand.trimmedDescription == node.rightOperand.trimmedDescription else { return }
        report(.identicalOperands, "Both operands of `\(op)` are `\(node.leftOperand.trimmedDescription)`.", at: node)
    }

    /// `if a {} else if a {}`: the second branch can never run. Only a chain of pure conditions is judged,
    /// because `if next() {} else if next() {}` is legitimate.
    func checkDuplicateConditions(_ node: IfExprSyntax) {
        guard isOn(.duplicateConditions), node.parent?.is(IfExprSyntax.self) != true else { return }
        var seen: Set<String> = []
        var current: IfExprSyntax? = node
        while let branch = current {
            if let key = conditionKey(branch.conditions), !seen.insert(key).inserted {
                report(.duplicateConditions, "This condition repeats an earlier one in the chain, so this branch never runs.", at: branch.conditions)
            }
            if case .ifExpr(let next)? = branch.elseBody { current = next } else { current = nil }
        }
    }

    /// The condition list with whitespace collapsed, or nil when it binds a pattern or has a side effect.
    private func conditionKey(_ conditions: ConditionElementListSyntax) -> String? {
        var parts: [String] = []
        for element in conditions {
            guard case .expression(let expression) = element.condition, isPure(expression) else { return nil }
            parts.append(expression.trimmedDescription.split(whereSeparator: \.isWhitespace).joined(separator: " "))
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// A class that keeps its `delegate` strongly while the delegate usually keeps the class. Only the exact
    /// name is judged, and only a stored, optional property in a class or actor: `previewDelegate` is often a
    /// helper object the class creates and owns, which `weak` would free at once. A closure, a computed
    /// property and a value type have no cycle to speak of.
    func checkDelegateNotWeak(_ node: VariableDeclSyntax) {
        guard isOn(.delegateNotWeak), node.bindingSpecifier.tokenKind == .keyword(.var), node.attributes.isEmpty,
              isStoredMemberOfClass(node) else { return }
        let skipped: Set<Keyword> = [.weak, .unowned, .static, .class, .lazy]
        for modifier in node.modifiers {
            if case .keyword(let keyword) = modifier.name.tokenKind, skipped.contains(keyword) { return }
        }
        for binding in node.bindings {
            guard binding.accessorBlock == nil, let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier,
                  name.text == "delegate",
                  let type = binding.typeAnnotation?.type,
                  type.is(OptionalTypeSyntax.self) || type.is(ImplicitlyUnwrappedOptionalTypeSyntax.self),
                  !type.trimmedDescription.hasPrefix("(") else { continue }
            report(.delegateNotWeak, "`\(name.text)` is held strongly; mark it `weak` to avoid a retain cycle.", at: name)
        }
    }

    private func isStoredMemberOfClass(_ node: VariableDeclSyntax) -> Bool {
        guard let block = node.parent?.as(MemberBlockItemSyntax.self)?.parent?.parent?.as(MemberBlockSyntax.self) else { return false }
        guard let owner = block.parent else { return false }
        return owner.is(ClassDeclSyntax.self) || owner.is(ActorDeclSyntax.self)
    }
}
