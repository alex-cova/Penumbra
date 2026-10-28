import Foundation
import SwiftSyntax

/// Replace every use of a local constant with its initializer and delete the declaration.
///
/// Only a `let` with one plain name and no written type is inlined. A value that is the same wherever it is
/// read (no call, `try`, `await` or closure in it) may replace any number of uses; one that does something
/// must have exactly one use, in the statement right after it and not inside a closure, a loop or a
/// short-circuit, so it still runs once and in the same order.
public enum SwiftInlineVariable {
    public static func isAvailable(in text: String, caret: Int) -> Bool {
        if case .success = edits(in: text, caret: caret) { return true }
        return false
    }

    public static func edits(in text: String, caret: Int) -> SwiftRefactoringResult {
        guard let file = SwiftRefactoringFile.load(text) else {
            return .failure(.init("The file has syntax errors; fix them before refactoring."))
        }
        let references = file.references
        guard let declaration = declaration(at: caret, file: file, references: references) else {
            return .failure(.init("Place the caret on a local constant or one of its uses."))
        }
        let pattern = declaration.binding.pattern
        guard declaration.decl.bindingSpecifier.tokenKind == .keyword(.let) else {
            return .failure(.init("Only a `let` can be inlined; a `var` may change between its declaration and its uses."))
        }
        guard declaration.decl.bindings.count == 1, declaration.decl.attributes.isEmpty, declaration.decl.modifiers.isEmpty,
              pattern.is(IdentifierPatternSyntax.self), declaration.binding.accessorBlock == nil else {
            return .failure(.init("This declaration is not a plain `let name = value`."))
        }
        if declaration.binding.typeAnnotation != nil {
            return .failure(.init("The constant has a written type, which a use may rely on."))
        }
        guard let initializer = declaration.binding.initializer?.value,
              let item = declaration.decl.parent?.as(CodeBlockItemSyntax.self),
              let list = item.parent?.as(CodeBlockItemListSyntax.self) else {
            return .failure(.init("Only a local constant with a value can be inlined."))
        }
        if let reason = unsuitable(initializer) { return .failure(.init(reason)) }

        let nameBytes = SwiftRefactoringFile.trimmed(pattern)
        let uses = references.filter { reference in
            if case .local(let declared, _) = reference.resolution { return declared == nameBytes }
            return false
        }
        guard !uses.isEmpty else { return .failure(.init("The constant is never used.")) }

        let itemRange = SwiftRefactoringFile.trimmed(item)
        let value = SwiftRefactoringFile.trimmed(initializer)
        let valueText = file.string(value)
        let isPure = SwiftExpressionPurity.isPure(initializer)
        if !isPure {
            guard let use = uses.first, uses.count == 1 else {
                return .failure(.init("The value does something, so it can replace only a single use."))
            }
            if let reason = singleUseProblem(use.bytes, item: item, list: list, file: file) { return .failure(.init(reason)) }
        } else if let reason = pureUsesProblem(uses, initializer: initializer, itemRange: itemRange, file: file) {
            return .failure(.init(reason))
        }
        return inlineEdits(file: file, item: item, itemRange: itemRange, valueText: valueText, initializer: initializer, uses: uses)
    }

    // MARK: - Finding the declaration

    private struct Declaration {
        let decl: VariableDeclSyntax
        let binding: PatternBindingSyntax
    }

    private static func declaration(at caret: Int, file: SwiftRefactoringFile, references: [SwiftSyntaxScopes.Reference]) -> Declaration? {
        var declaredAt: Range<Int>?
        if let use = references.first(where: { $0.bytes.contains(caret) || $0.bytes.upperBound == caret }),
           case .local(let declared, _) = use.resolution {
            declaredAt = declared
        } else {
            declaredAt = nil
        }
        let probe = declaredAt?.lowerBound ?? caret
        guard probe < file.utf8.count || probe > 0,
              let token = file.tree.token(at: AbsolutePosition(utf8Offset: min(probe, max(file.utf8.count - 1, 0)))) else { return nil }
        var node: Syntax? = Syntax(token)
        while let current = node {
            if let binding = current.as(PatternBindingSyntax.self), let decl = binding.parent?.parent?.as(VariableDeclSyntax.self) {
                let name = SwiftRefactoringFile.trimmed(binding.pattern)
                guard name.contains(probe) || name.upperBound == probe else { return nil }
                return Declaration(decl: decl, binding: binding)
            }
            if current.is(CodeBlockItemSyntax.self) { return nil }
            node = current.parent
        }
        return nil
    }

    private static func unsuitable(_ initializer: ExprSyntax) -> String? {
        let finder = ForbiddenFinder()
        finder.walk(initializer)
        return finder.reason
    }

    private final class ForbiddenFinder: SyntaxVisitor {
        var reason: String?

        init() { super.init(viewMode: .sourceAccurate) }

        override func visit(_ node: TryExprSyntax) -> SyntaxVisitorContinueKind { stop("The value uses `try`.") }
        override func visit(_ node: AwaitExprSyntax) -> SyntaxVisitorContinueKind { stop("The value uses `await`.") }
        override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { stop("The value is or contains a closure.") }
        override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind { stop("The value uses a macro.") }
        override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
            node.baseName.text.hasPrefix("$") && node.baseName.text.dropFirst().allSatisfy(\.isNumber) && node.baseName.text.count > 1
                ? stop("The value uses an anonymous closure parameter.") : .visitChildren
        }

        private func stop(_ message: String) -> SyntaxVisitorContinueKind {
            reason = reason ?? message
            return .skipChildren
        }
    }

    // MARK: - Where it may go

    /// A value with an effect: its one use is in the next statement, evaluated once, unconditionally.
    private static func singleUseProblem(
        _ use: Range<Int>, item: CodeBlockItemSyntax, list: CodeBlockItemListSyntax, file: SwiftRefactoringFile
    ) -> String? {
        let message = "The value does something, so it can only move into the statement right after it, where it still runs once: "
        guard let next = list.index(of: item).map({ list.index(after: $0) }), next < list.endIndex else {
            return message + "there is no statement after it."
        }
        let following = list[next]
        let followingRange = SwiftRefactoringFile.trimmed(following)
        guard followingRange.contains(use.lowerBound) else { return message + "the use is further away." }
        guard let token = file.tree.token(at: AbsolutePosition(utf8Offset: use.lowerBound)) else { return message + "the use cannot be found." }
        var node: Syntax? = Syntax(token)
        var child: Syntax = Syntax(token)
        while let current = node, current.id != following.id {
            if current.is(ClosureExprSyntax.self) || current.is(ForStmtSyntax.self) || current.is(WhileStmtSyntax.self)
                || current.is(RepeatStmtSyntax.self) || current.is(FunctionDeclSyntax.self) || current.is(DeferStmtSyntax.self) {
                return message + "the use is inside a closure, loop or function."
            }
            if let infix = current.as(InfixOperatorExprSyntax.self), let op = infix.operator.as(BinaryOperatorExprSyntax.self),
               ["&&", "||", "??"].contains(op.operator.text), infix.rightOperand.id == child.id {
                return message + "the use is only evaluated conditionally."
            }
            if let ternary = current.as(TernaryExprSyntax.self), ternary.condition.id != child.id {
                return message + "the use is only evaluated conditionally."
            }
            if current.is(CodeBlockSyntax.self) || current.is(SwitchCaseSyntax.self) {
                return message + "the use is inside a nested block."
            }
            child = current
            node = current.parent
        }
        return nil
    }

    /// Several uses of a value that is the same each time: none may sit where a name it mentions is rebound,
    /// or inside a closure that could run after the names change.
    private static func pureUsesProblem(
        _ uses: [SwiftSyntaxScopes.Reference], initializer: ExprSyntax, itemRange: Range<Int>, file: SwiftRefactoringFile
    ) -> String? {
        let mentioned = memberRootNames(of: initializer)
        let last = uses.map(\.bytes.upperBound).max() ?? itemRange.upperBound
        let rebinding = RebindingFinder(names: mentioned, region: itemRange.upperBound ..< last)
        rebinding.walk(file.tree)
        if let name = rebinding.found { return "`\(name)` is declared again between the constant and a use, so the value would change." }
        for use in uses {
            guard let token = file.tree.token(at: AbsolutePosition(utf8Offset: use.bytes.lowerBound)) else { continue }
            var node: Syntax? = Syntax(token)
            while let current = node {
                if current.is(ClosureExprSyntax.self) || current.is(FunctionDeclSyntax.self) {
                    let range = SwiftRefactoringFile.trimmed(current)
                    if range.lowerBound > itemRange.upperBound {
                        return "A use is inside a closure or function, which may run after the value's inputs change."
                    }
                }
                node = current.parent
            }
        }
        return nil
    }

    private static func memberRootNames(of expression: ExprSyntax) -> Set<String> {
        let collector = RootNames()
        collector.walk(expression)
        return collector.names
    }

    private final class RootNames: SyntaxVisitor {
        var names = Set<String>()

        init() { super.init(viewMode: .sourceAccurate) }

        override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
            names.insert(node.baseName.text)
            return .visitChildren
        }
    }

    private final class RebindingFinder: SyntaxVisitor {
        let names: Set<String>
        let region: Range<Int>
        var found: String?

        init(names: Set<String>, region: Range<Int>) {
            self.names = names
            self.region = region
            super.init(viewMode: .sourceAccurate)
        }

        private func note(_ token: TokenSyntax) {
            let start = token.positionAfterSkippingLeadingTrivia.utf8Offset
            if region.contains(start), names.contains(token.text) { found = found ?? token.text }
        }

        override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind { note(node.identifier); return .visitChildren }
        override func visit(_ node: FunctionParameterSyntax) -> SyntaxVisitorContinueKind { note(node.secondName ?? node.firstName); return .visitChildren }
        override func visit(_ node: ClosureParameterSyntax) -> SyntaxVisitorContinueKind { note(node.secondName ?? node.firstName); return .visitChildren }
        override func visit(_ node: ClosureShorthandParameterSyntax) -> SyntaxVisitorContinueKind { note(node.name); return .visitChildren }
        override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { note(node.name); return .visitChildren }
    }

    // MARK: - Edits

    private static func inlineEdits(
        file: SwiftRefactoringFile, item: CodeBlockItemSyntax, itemRange: Range<Int>, valueText: String,
        initializer: ExprSyntax, uses: [SwiftSyntaxScopes.Reference]
    ) -> SwiftRefactoringResult {
        var edits: [SwiftTextEdit] = []
        let atomic = isAtomic(initializer)
        for use in uses {
            let inInterpolation = isInInterpolation(use.bytes, file: file)
            let text = atomic || inInterpolation ? valueText : "(\(valueText))"
            edits.append(SwiftTextEdit(bytes: use.bytes, replacement: text))
        }
        edits.append(SwiftTextEdit(bytes: removalRange(of: item, itemRange: itemRange, file: file), replacement: ""))
        return .success(edits)
    }

    /// The statement and the line it leaves empty.
    private static func removalRange(of item: CodeBlockItemSyntax, itemRange: Range<Int>, file: SwiftRefactoringFile) -> Range<Int> {
        var lower = itemRange.lowerBound
        var upper = itemRange.upperBound
        if upper < file.utf8.count, file.utf8[upper] == UInt8(ascii: ";") { upper += 1 }
        var lineStart = lower
        while lineStart > 0, file.utf8[lineStart - 1] == 0x20 || file.utf8[lineStart - 1] == 0x09 { lineStart -= 1 }
        var lineEnd = upper
        while lineEnd < file.utf8.count, file.utf8[lineEnd] == 0x20 || file.utf8[lineEnd] == 0x09 { lineEnd += 1 }
        let startsLine = lineStart == 0 || file.utf8[lineStart - 1] == 0x0A
        let endsLine = lineEnd >= file.utf8.count || file.utf8[lineEnd] == 0x0A || file.utf8[lineEnd] == 0x0D
        if startsLine, endsLine {
            lower = lineStart
            upper = lineEnd
            if upper < file.utf8.count, file.utf8[upper] == 0x0D { upper += 1 }
            if upper < file.utf8.count, file.utf8[upper] == 0x0A { upper += 1 }
        }
        return lower ..< upper
    }

    private static func isInInterpolation(_ bytes: Range<Int>, file: SwiftRefactoringFile) -> Bool {
        guard let token = file.tree.token(at: AbsolutePosition(utf8Offset: bytes.lowerBound)) else { return false }
        var node: Syntax? = Syntax(token)
        while let current = node {
            if current.is(ExpressionSegmentSyntax.self) { return true }
            node = current.parent
        }
        return false
    }

    /// Whether the expression can follow a `.`, be an operand or an argument without parentheses.
    private static func isAtomic(_ expression: ExprSyntax) -> Bool {
        expression.is(DeclReferenceExprSyntax.self) || expression.is(FunctionCallExprSyntax.self)
            || expression.is(SubscriptCallExprSyntax.self) || expression.is(StringLiteralExprSyntax.self)
            || expression.is(BooleanLiteralExprSyntax.self) || expression.is(IntegerLiteralExprSyntax.self)
            || expression.is(FloatLiteralExprSyntax.self) || expression.is(ArrayExprSyntax.self)
            || expression.is(DictionaryExprSyntax.self) || expression.is(TupleExprSyntax.self)
            || expression.is(ForceUnwrapExprSyntax.self)
            || (expression.as(MemberAccessExprSyntax.self).map { $0.base != nil } ?? false)
    }
}

/// Whether evaluating an expression twice can differ from evaluating it once.
enum SwiftExpressionPurity {
    static func isPure(_ expression: some SyntaxProtocol) -> Bool {
        let visitor = Visitor()
        visitor.walk(expression)
        return visitor.isPure
    }

    private final class Visitor: SyntaxVisitor {
        var isPure = true

        init() { super.init(viewMode: .sourceAccurate) }

        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind { impure() }
        override func visit(_ node: AwaitExprSyntax) -> SyntaxVisitorContinueKind { impure() }
        override func visit(_ node: TryExprSyntax) -> SyntaxVisitorContinueKind { impure() }
        override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { impure() }
        override func visit(_ node: AssignmentExprSyntax) -> SyntaxVisitorContinueKind { impure() }
        override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind { impure() }

        private func impure() -> SyntaxVisitorContinueKind {
            isPure = false
            return .skipChildren
        }
    }
}
