import Foundation
import SwiftSyntax

/// `if let` ↔ `guard let`.
///
/// `if conditions { body }` that ends its block becomes `guard conditions else { return }` followed by the body when
/// leaving early is the same as falling off the end: in a function that returns nothing (`return`) or in a loop
/// body (`continue`). `guard conditions else { return }` followed by the rest of its block becomes
/// `if conditions { rest }` when that else branch only exits, so nothing after the guard is skipped.
public enum SwiftConditionalConversion {
    public enum Direction: Sendable {
        case ifToGuard
        case guardToIf
    }

    /// The conversion available with the caret on the `if` / `guard` keyword's statement.
    public static func available(in text: String, caret: Int) -> Direction? {
        guard let file = SwiftRefactoringFile.load(text), let item = statement(at: caret, file: file) else { return nil }
        if case .success = convertIf(item, file: file) { return .ifToGuard }
        if case .success = convertGuard(item, file: file) { return .guardToIf }
        return nil
    }

    public static func edits(in text: String, caret: Int) -> SwiftRefactoringResult {
        guard let file = SwiftRefactoringFile.load(text) else {
            return .failure(.init("The file has syntax errors; fix them before refactoring."))
        }
        guard let item = statement(at: caret, file: file) else {
            return .failure(.init("Place the caret on an `if` or `guard` statement."))
        }
        if item.item.is(GuardStmtSyntax.self) { return convertGuard(item, file: file) }
        return convertIf(item, file: file)
    }

    /// The `if` or `guard` statement the caret is on the first line of (its keyword or its conditions).
    private static func statement(at caret: Int, file: SwiftRefactoringFile) -> CodeBlockItemSyntax? {
        guard let token = file.tree.token(at: AbsolutePosition(utf8Offset: min(max(caret, 0), max(file.utf8.count - 1, 0)))) else { return nil }
        var node: Syntax? = Syntax(token)
        var item: CodeBlockItemSyntax?
        while let current = node {
            if let found = current.as(CodeBlockItemSyntax.self) {
                guard found.item.is(IfExprSyntax.self) || found.item.is(GuardStmtSyntax.self) || found.item.as(ExpressionStmtSyntax.self)?.expression.is(IfExprSyntax.self) == true else {
                    node = current.parent
                    continue
                }
                item = found
                break
            }
            node = current.parent
        }
        guard let item else { return nil }
        // Only on the header: inside the body the caret belongs to something else.
        let range = SwiftRefactoringFile.trimmed(item)
        let body: Range<Int>?
        if let ifExpr = ifExpression(of: item) { body = SwiftRefactoringFile.trimmed(ifExpr.body) }
        else if let guardStmt = item.item.as(GuardStmtSyntax.self) { body = SwiftRefactoringFile.trimmed(guardStmt.body) }
        else { body = nil }
        if let body, caret >= body.lowerBound, caret < body.upperBound { return nil }
        return range.contains(caret) || range.upperBound == caret ? item : nil
    }

    private static func ifExpression(of item: CodeBlockItemSyntax) -> IfExprSyntax? {
        item.item.as(IfExprSyntax.self) ?? item.item.as(ExpressionStmtSyntax.self)?.expression.as(IfExprSyntax.self)
    }

    // MARK: - if → guard

    private static func convertIf(_ item: CodeBlockItemSyntax, file: SwiftRefactoringFile) -> SwiftRefactoringResult {
        guard let ifExpr = ifExpression(of: item) else { return .failure(.init("Place the caret on an `if` statement.")) }
        guard ifExpr.elseBody == nil else { return .failure(.init("An `if` with an `else` cannot become a `guard`.")) }
        guard let list = item.parent?.as(CodeBlockItemListSyntax.self), list.last?.id == item.id else {
            return .failure(.init("Only the last statement of a block can become a `guard`: the code after it would no longer run."))
        }
        guard ifExpr.conditions.contains(where: { $0.condition.is(OptionalBindingConditionSyntax.self) }) else {
            return .failure(.init("Only an `if let` / `if case` style condition is turned into a `guard`."))
        }
        guard let exit = exitStatement(for: list) else {
            return .failure(.init("Cannot tell how to leave early here; the block must be a function that returns nothing or a loop body."))
        }
        let body = ifExpr.body.statements
        if body.contains(where: { $0.item.is(DeferStmtSyntax.self) }) {
            return .failure(.init("The body has a `defer`, which would then run at the end of the enclosing block."))
        }
        let declared = declaredNames(in: list, before: item)
        var introduced = Set<String>()
        for element in ifExpr.conditions {
            if let binding = element.condition.as(OptionalBindingConditionSyntax.self) {
                IdentifierBinder.collect(binding.pattern, into: &introduced)
            }
        }
        for statement in body { IdentifierBinder.collectDeclarations(of: statement, into: &introduced) }
        if let clash = introduced.first(where: declared.contains) {
            return .failure(.init("`\(clash)` is already declared in the enclosing block, so it cannot be declared there again."))
        }

        let itemRange = SwiftRefactoringFile.trimmed(item)
        guard let indent = file.indentation(before: itemRange.lowerBound) else {
            return .failure(.init("The `if` shares its line with other code."))
        }
        let conditions = file.string(SwiftRefactoringFile.trimmed(ifExpr.conditions))
        var text = "guard \(conditions) else { \(exit) }"
        if !body.isEmpty {
            let bodyRange = file.trimmedBytes(ifExpr.body.statements.position.utf8Offset ..< ifExpr.body.statements.endPosition.utf8Offset)
            let unit = unitIndent(forBlockAt: bodyRange.lowerBound, parentIndent: indent, file: file)
            text += "\n" + dedent(file.string(bodyRange), by: unit, firstLineIndent: indent, file: file)
        }
        return .success([SwiftTextEdit(bytes: itemRange, replacement: text)])
    }

    private static func exitStatement(for list: CodeBlockItemListSyntax) -> String? {
        guard let owner = list.parent else { return nil }
        if let block = owner.as(CodeBlockSyntax.self), let parent = block.parent {
            if parent.is(ForStmtSyntax.self) || parent.is(WhileStmtSyntax.self) || parent.is(RepeatStmtSyntax.self) { return "continue" }
            if let function = parent.as(FunctionDeclSyntax.self) {
                guard let clause = function.signature.returnClause else { return "return" }
                let type = clause.type
                let isVoid = type.as(IdentifierTypeSyntax.self).map { $0.name.text == "Void" } ?? false
                    || (type.as(TupleTypeSyntax.self)?.elements.isEmpty ?? false)
                return isVoid ? "return" : nil
            }
        }
        return nil
    }

    // MARK: - guard → if

    private static func convertGuard(_ item: CodeBlockItemSyntax, file: SwiftRefactoringFile) -> SwiftRefactoringResult {
        guard let guardStmt = item.item.as(GuardStmtSyntax.self) else { return .failure(.init("Place the caret on a `guard` statement.")) }
        guard guardStmt.body.statements.count == 1, let only = guardStmt.body.statements.first else {
            return .failure(.init("Only a `guard` whose `else` just leaves can become an `if`; the `else` does more."))
        }
        let exit = only.item
        let leaves = exit.as(ReturnStmtSyntax.self).map { $0.expression == nil }
            ?? (exit.as(ContinueStmtSyntax.self)?.label == nil && exit.is(ContinueStmtSyntax.self))
            || (exit.as(BreakStmtSyntax.self).map { $0.label == nil } ?? false)
        guard leaves else { return .failure(.init("Only a bare `return`, `continue` or `break` in the `else` can be dropped.")) }
        guard let list = item.parent?.as(CodeBlockItemListSyntax.self) else { return .failure(.init("The `guard` is not in a block.")) }
        let rest = Array(list.drop { $0.id != item.id }.dropFirst())
        let itemRange = SwiftRefactoringFile.trimmed(item)
        guard let indent = file.indentation(before: itemRange.lowerBound) else {
            return .failure(.init("The `guard` shares its line with other code."))
        }
        let conditions = file.string(SwiftRefactoringFile.trimmed(guardStmt.conditions))
        guard let first = rest.first, let last = rest.last else {
            return .success([SwiftTextEdit(bytes: itemRange, replacement: "if \(conditions) { }")])
        }
        let restRange = SwiftRefactoringFile.trimmed(first).lowerBound ..< SwiftRefactoringFile.trimmed(last).upperBound
        let unit = unitIndent(forBlockAt: SwiftRefactoringFile.trimmed(only).lowerBound, parentIndent: indent, file: file)
        let body = indentText(file.string(restRange), by: unit, firstLineIndent: indent, file: file, bytes: restRange)
        let replacement = "if \(conditions) {\n" + body + "\n\(indent)}"
        return .success([SwiftTextEdit(bytes: itemRange.lowerBound ..< restRange.upperBound, replacement: replacement)])
    }

    // MARK: - Names and layout

    private static func declaredNames(in list: CodeBlockItemListSyntax, before item: CodeBlockItemSyntax) -> Set<String> {
        var names = Set<String>()
        for sibling in list {
            if sibling.id == item.id { break }
            IdentifierBinder.collectDeclarations(of: sibling, into: &names)
        }
        return names
    }

    /// One level of indentation, from how far the block's first statement is indented past its parent.
    private static func unitIndent(forBlockAt byte: Int, parentIndent: String, file: SwiftRefactoringFile) -> String {
        if let own = file.indentation(before: byte), own.hasPrefix(parentIndent), own.count > parentIndent.count {
            return String(own.dropFirst(parentIndent.count))
        }
        return parentIndent.contains("\t") ? "\t" : "    "
    }

    /// `text` with one `unit` removed from each line after the first; the first line starts at `firstLineIndent`.
    private static func dedent(_ text: String, by unit: String, firstLineIndent: String, file: SwiftRefactoringFile) -> String {
        var lines = text.components(separatedBy: "\n")
        for index in lines.indices.dropFirst() where lines[index].hasPrefix(unit) { lines[index].removeFirst(unit.count) }
        guard !lines.isEmpty else { return text }
        lines[0] = firstLineIndent + lines[0]
        return lines.joined(separator: "\n")
    }

    /// `text` with one `unit` added to every non-empty line; the first line also gets the parent's indent first.
    private static func indentText(_ text: String, by unit: String, firstLineIndent: String, file: SwiftRefactoringFile, bytes: Range<Int>) -> String {
        var lines = text.components(separatedBy: "\n")
        for index in lines.indices where !lines[index].isEmpty {
            lines[index] = (index == 0 ? firstLineIndent + unit : unit) + lines[index]
        }
        return lines.joined(separator: "\n")
    }
}

/// The names a pattern or declaration introduces.
enum IdentifierBinder {
    static func collect(_ pattern: some SyntaxProtocol, into names: inout Set<String>) {
        let finder = Finder()
        finder.walk(pattern)
        names.formUnion(finder.names)
    }

    /// Names declared by a statement itself: its `let`/`var`/`func`/type declarations, not those nested in its blocks.
    static func collectDeclarations(of item: CodeBlockItemSyntax, into names: inout Set<String>) {
        if let variable = item.item.as(VariableDeclSyntax.self) {
            for binding in variable.bindings { collect(binding.pattern, into: &names) }
        } else if let function = item.item.as(FunctionDeclSyntax.self) {
            names.insert(function.name.text)
        } else if let decl = item.item.asProtocol(NamedDeclSyntax.self) {
            names.insert(decl.name.text)
        }
    }

    private final class Finder: SyntaxVisitor {
        var names = Set<String>()

        init() { super.init(viewMode: .sourceAccurate) }

        override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
            names.insert(node.identifier.text)
            return .visitChildren
        }
    }
}
