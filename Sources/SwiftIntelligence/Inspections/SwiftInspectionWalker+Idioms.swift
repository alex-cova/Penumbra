import Foundation
import SwiftSyntax

// Idioms: the same result, written the way the standard library intends.
extension SwiftInspectionWalker {
    /// `x.count == 0`, `x.count != 0`, `x.count > 0` (and `0 == x.count`). `count` can be linear (a `String`'s
    /// is) and `isEmpty` is not. The message names the one way this is wrong: a type with `count` and no
    /// `isEmpty`. Optional chaining (`x?.count == 0`) is skipped, because `nil == 0` is false and
    /// `x?.isEmpty` is nil.
    func checkCountIsZero(_ node: InfixOperatorExprSyntax) {
        guard isOn(.countIsZero), !declaresCountWithoutIsEmpty, let op = operatorText(of: node), ["==", "!=", ">"].contains(op) else { return }
        let countSide: ExprSyntax
        if isIntegerLiteral(node.rightOperand, "0") {
            countSide = node.leftOperand
        } else if op != ">", isIntegerLiteral(node.leftOperand, "0") {
            countSide = node.rightOperand
        } else {
            return
        }
        guard let member = countSide.as(MemberAccessExprSyntax.self), member.declName.baseName.text == "count",
              member.declName.argumentNames == nil, let base = member.base, !hasOptionalChaining(base) else { return }
        let negated = op != "=="
        let replacement = (negated ? "!" : "") + base.trimmedDescription + ".isEmpty"
        report(
            .countIsZero, "Use `isEmpty` instead of comparing `count` with zero (unless the type has no `isEmpty`).", at: node,
            fixes: [fix(negated ? "Replace with '!isEmpty'" : "Replace with 'isEmpty'", edit(bytes(node), replacement))]
        )
    }

    /// `x.filter { … }.first` and `.last`: a whole array is built to take one element. The fix is offered for
    /// `first` only, because `last(where:)` exists on bidirectional collections and not on every sequence.
    func checkFilterFirst(_ node: MemberAccessExprSyntax) {
        guard isOn(.filterFirst), !isCalled(node) else { return }
        let end = node.declName.baseName.text
        guard end == "first" || end == "last", let call = node.base?.as(FunctionCallExprSyntax.self),
              let filter = call.calledExpression.as(MemberAccessExprSyntax.self), filter.base != nil,
              filter.declName.baseName.text == "filter", filter.declName.argumentNames == nil else { return }
        let isTrailing = call.leftParen == nil && call.trailingClosure != nil && call.arguments.isEmpty
        let isParenthesized = call.leftParen != nil && call.trailingClosure == nil
            && call.arguments.count == 1 && call.arguments.first?.label == nil
        guard isTrailing || isParenthesized else { return }

        var fixes: [SwiftInspectionFix] = []
        if end == "first" {
            let suffix = bytes(call).upperBound ..< bytes(node).upperBound
            let rename = isTrailing
                ? edit(bytes(filter.declName), "first")
                : edit(bytes(filter.declName).lowerBound ..< bytes(call.leftParen!).upperBound, "first(where: ")
            fixes = [fix("Use 'first(where:)'", rename, edit(suffix, ""))]
        }
        report(
            .filterFirst, "`filter` builds a whole array to take its \(end) element; use `\(end)(where:)`.",
            at: filter.declName, fixes: fixes
        )
    }

    /// `x.sorted().first` is `x.min()` and `.last` is `.max()`. Only the argument-free `sorted()` qualifies:
    /// with a comparator the answer is `min(by:)`, and that is a different edit.
    func checkSortedFirst(_ node: MemberAccessExprSyntax) {
        guard isOn(.sortedFirst), !isCalled(node) else { return }
        let end = node.declName.baseName.text
        guard end == "first" || end == "last", let call = node.base?.as(FunctionCallExprSyntax.self),
              let sorted = call.calledExpression.as(MemberAccessExprSyntax.self), sorted.base != nil,
              sorted.declName.baseName.text == "sorted", sorted.declName.argumentNames == nil,
              call.arguments.isEmpty, call.trailingClosure == nil else { return }
        let replacement = end == "first" ? "min()" : "max()"
        let removal = bytes(sorted.declName).lowerBound ..< bytes(node).upperBound
        report(
            .sortedFirst, "Sorting to find the \(end == "first" ? "smallest" : "largest") element is linear work done in n log n.",
            at: sorted.declName, fixes: [fix("Use '\(replacement)'", edit(removal, replacement))]
        )
    }

    /// `x.first(where: p) != nil` is `x.contains(where: p)`, and `== nil` is its negation.
    func checkFirstWhereNil(_ node: InfixOperatorExprSyntax) {
        guard isOn(.firstWhereNil), let op = operatorText(of: node), op == "!=" || op == "==",
              node.rightOperand.is(NilLiteralExprSyntax.self), let call = node.leftOperand.as(FunctionCallExprSyntax.self),
              let first = call.calledExpression.as(MemberAccessExprSyntax.self), first.base != nil,
              first.declName.baseName.text == "first", first.declName.argumentNames == nil else { return }
        let hasWhere = call.arguments.first?.label?.text == "where"
        let isTrailing = call.arguments.isEmpty && call.trailingClosure != nil
        guard hasWhere || isTrailing else { return }
        var edits = [edit(bytes(first.declName), "contains"), edit(bytes(call).upperBound ..< bytes(node).upperBound, "")]
        if op == "==" { edits.insert(edit(bytes(call).lowerBound ..< bytes(call).lowerBound, "!"), at: 0) }
        report(
            .firstWhereNil, "Use `contains(where:)` instead of comparing `first(where:)` with nil.", at: node,
            fixes: [SwiftInspectionFix(title: "Use 'contains(where:)'", edits: edits)]
        )
    }

    /// A bare call to `print`, `debugPrint` or `dump`.
    func checkLeftoverPrint(_ node: FunctionCallExprSyntax) {
        guard isOn(.leftoverPrint), let callee = node.calledExpression.as(DeclReferenceExprSyntax.self),
              ["print", "debugPrint", "dump"].contains(callee.baseName.text) else { return }
        report(.leftoverPrint, "`\(callee.baseName.text)` writes to standard output; remove it or use a logger.", at: callee)
    }
}
