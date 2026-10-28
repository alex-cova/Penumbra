import Foundation
import SwiftSyntax

/// Extract the selected expression into a new `let` above the statement it is in.
///
/// An expression is only moved where moving it cannot change what the program does or stop it compiling:
/// not out of a short-circuit (`&&`, `||`, `??`, a ternary branch, an `else if`, a later `if` condition), not out
/// of a loop condition, not away from the names a statement itself declares, and not an expression whose type
/// comes from where it is used (a number literal, `.member`, a closure, `nil`).
public enum SwiftIntroduceVariable {
    public static func suggestedName(in text: String, selection: Range<Int>) -> String? {
        guard let file = SwiftRefactoringFile.load(text),
              let expression = file.expression(exactly: file.trimmedBytes(selection)) else { return nil }
        return name(for: expression, avoiding: usedNames(in: file))
    }

    public static func edits(in text: String, selection: Range<Int>, name requested: String) -> SwiftRefactoringResult {
        guard SwiftIdentifiers.isValid(requested) else { return .failure(.init("'\(requested)' is not a valid name.")) }
        guard let file = SwiftRefactoringFile.load(text) else {
            return .failure(.init("The file has syntax errors; fix them before refactoring."))
        }
        let bytes = file.trimmedBytes(selection)
        guard let expression = file.expression(exactly: bytes) else {
            return .failure(.init("Select one complete expression."))
        }
        if let reason = unsuitable(expression) { return .failure(.init(reason)) }
        guard let item = SwiftRefactoringFile.enclosingItem(of: expression) else {
            return .failure(.init("The expression is not inside a function body or other code block."))
        }
        if let reason = movesOutOfContext(expression, item: item) { return .failure(.init(reason)) }

        let itemStart = item.positionAfterSkippingLeadingTrivia.utf8Offset
        if let reason = usesNamesDeclaredInside(bytes, itemStart: itemStart, file: file) { return .failure(.init(reason)) }

        var prefix = ""
        switch effects(above: expression, within: item) {
        case .failure(let failure): return .failure(failure)
        case .success(let words): prefix = words
        }
        let declaration = "let \(requested) = \(prefix)\(file.string(bytes))"
        let indent = file.indentation(before: itemStart)
        // A body that is one expression returns it implicitly; once a statement is added before it, it must say so.
        var returns = false
        switch implicitReturn(of: item) {
        case .notImplicit, .returnsNothing: break
        case .returnsValue: returns = true
        case .unknown:
            return .failure(.init("This closure may return a value, and adding a statement to it changes how it is read; extract inside a closure whose result is clear."))
        }
        let separator = indent.map { "\n" + $0 } ?? "; "
        let lead = declaration + separator + (returns ? "return " : "")
        let keptStart = file.string(itemStart ..< bytes.lowerBound)
        return .success([SwiftTextEdit(bytes: itemStart ..< bytes.upperBound, replacement: lead + keptStart + requested)])
    }

    // MARK: - What can be extracted

    private static func unsuitable(_ expression: ExprSyntax) -> String? {
        let message = "This expression cannot be extracted safely: "
        if expression.is(ClosureExprSyntax.self) { return message + "a closure's type comes from where it is used." }
        if expression.is(IntegerLiteralExprSyntax.self) || expression.is(FloatLiteralExprSyntax.self) {
            return message + "the type of a number literal comes from where it is used."
        }
        if expression.is(NilLiteralExprSyntax.self) || expression.is(ArrayExprSyntax.self) || expression.is(DictionaryExprSyntax.self) {
            return message + "its type comes from where it is used."
        }
        if let access = expression.as(MemberAccessExprSyntax.self), access.base == nil {
            return message + "an implicit member needs its context."
        }
        if let reference = expression.as(DeclReferenceExprSyntax.self), reference.baseName.text.first?.isUppercase == true {
            return message + "that is a type, not a value."
        }
        let allowed = expression.is(FunctionCallExprSyntax.self) || expression.is(MemberAccessExprSyntax.self)
            || expression.is(DeclReferenceExprSyntax.self) || expression.is(SubscriptCallExprSyntax.self)
            || expression.is(InfixOperatorExprSyntax.self) || expression.is(TernaryExprSyntax.self)
            || expression.is(PrefixOperatorExprSyntax.self) || expression.is(PostfixOperatorExprSyntax.self)
            || expression.is(ForceUnwrapExprSyntax.self) || expression.is(StringLiteralExprSyntax.self)
            || expression.is(BooleanLiteralExprSyntax.self) || expression.is(TupleExprSyntax.self)
            || expression.is(AsExprSyntax.self) || expression.is(IsExprSyntax.self)
            || expression.is(AwaitExprSyntax.self) || expression.is(TryExprSyntax.self)
        guard allowed else { return message + "select a value expression." }
        if let infix = expression.as(InfixOperatorExprSyntax.self), infix.operator.is(AssignmentExprSyntax.self) {
            return message + "an assignment is not a value."
        }
        if let tuple = expression.as(TupleExprSyntax.self), tuple.elements.contains(where: { $0.label != nil }) {
            return message + "a labeled tuple's type comes from where it is used."
        }
        // The called function of a call, an `inout` argument, the target of an assignment.
        if let parent = expression.parent {
            if let call = parent.as(FunctionCallExprSyntax.self), call.calledExpression.id == expression.id {
                return message + "it names the function being called."
            }
            if parent.is(InOutExprSyntax.self) { return message + "it is passed `inout`." }
            if let infix = parent.as(InfixOperatorExprSyntax.self), infix.operator.is(AssignmentExprSyntax.self),
               infix.leftOperand.id == expression.id {
                return message + "it is assigned to."
            }
            if parent.is(KeyPathExprSyntax.self) || parent.is(KeyPathComponentSyntax.self) { return message + "it is part of a key path." }
            if let access = parent.as(MemberAccessExprSyntax.self), access.base?.id == expression.id,
               expression.is(DeclReferenceExprSyntax.self) == false, hasOptionalChain(access) {
                return message + "it starts an optional chain."
            }
            if parent.is(OptionalChainingExprSyntax.self) { return message + "it starts an optional chain." }
        }
        return nil
    }

    private static func hasOptionalChain(_ access: MemberAccessExprSyntax) -> Bool {
        var node: Syntax? = Syntax(access)
        while let current = node {
            if current.is(OptionalChainingExprSyntax.self) { return true }
            if current.is(MemberAccessExprSyntax.self) || current.is(FunctionCallExprSyntax.self)
                || current.is(SubscriptCallExprSyntax.self) { node = current.parent } else { break }
        }
        return false
    }

    /// Why hoisting the expression above `item` would change how often or whether it runs.
    private static func movesOutOfContext(_ expression: ExprSyntax, item: CodeBlockItemSyntax) -> String? {
        let message = "Moving this expression above the statement would change when it runs: "
        var child: Syntax = Syntax(expression)
        while let parent = child.parent, parent.id != item.id {
            if let infix = parent.as(InfixOperatorExprSyntax.self), let op = infix.operator.as(BinaryOperatorExprSyntax.self),
               ["&&", "||", "??"].contains(op.operator.text), infix.rightOperand.id == child.id {
                return message + "it is only evaluated when `\(op.operator.text)` needs it."
            }
            if let ternary = parent.as(TernaryExprSyntax.self), ternary.condition.id != child.id {
                return message + "it is one branch of a conditional expression."
            }
            if let element = parent.as(ConditionElementSyntax.self), let list = element.parent?.as(ConditionElementListSyntax.self) {
                if list.first?.id != element.id { return message + "it follows another condition." }
                if let owner = list.parent {
                    if owner.is(WhileStmtSyntax.self) { return message + "it is a loop condition." }
                    if let ifExpr = owner.as(IfExprSyntax.self), ifExpr.parent?.is(IfExprSyntax.self) == true {
                        return message + "it is in an `else if`."
                    }
                }
            }
            if parent.is(RepeatStmtSyntax.self) { return message + "it is a loop condition." }
            if parent.is(WhereClauseSyntax.self) { return message + "it is a `where` clause." }
            if let call = parent.as(FunctionCallExprSyntax.self), let callee = call.calledExpression.as(DeclReferenceExprSyntax.self),
               ["assert", "precondition", "assertionFailure", "preconditionFailure"].contains(callee.baseName.text)
                || callee.baseName.text.hasPrefix("XCTAssert") {
                return message + "the call takes it as an autoclosure."
            }
            if parent.is(SwitchCaseItemSyntax.self) || parent.is(SwitchCaseLabelSyntax.self) { return message + "it is in a `case` pattern." }
            child = parent
        }
        // A statement that is itself an expression branch (`let x = if c { … }`) cannot take another statement.
        if let block = item.parent?.parent, let owner = block.parent {
            let branch = owner.is(IfExprSyntax.self) || owner.is(SwitchCaseSyntax.self)
            if branch, let expressionOwner = owner.is(SwitchCaseSyntax.self) ? owner.parent?.parent?.parent : owner.parent,
               !(expressionOwner.is(CodeBlockItemSyntax.self)), !(expressionOwner.is(IfExprSyntax.self)),
               !(expressionOwner.is(SwitchExprSyntax.self) && expressionOwner.parent?.is(CodeBlockItemSyntax.self) == true) {
                return "A branch of an `if` or `switch` used as a value must stay one expression."
            }
        }
        return nil
    }

    private static func usesNamesDeclaredInside(_ bytes: Range<Int>, itemStart: Int, file: SwiftRefactoringFile) -> String? {
        for reference in file.references where bytes.contains(reference.bytes.lowerBound) {
            if case .local(let declaration, _) = reference.resolution, declaration.lowerBound >= itemStart {
                return "The expression uses `\(reference.name)`, which this statement declares."
            }
        }
        // Anonymous closure parameters of a closure that the selection does not contain.
        var found: String?
        let finder = AnonymousParameterFinder(bytes: bytes, itemStart: itemStart) { found = $0 }
        finder.walk(file.tree)
        return found
    }

    private final class AnonymousParameterFinder: SyntaxVisitor {
        let bytes: Range<Int>
        let itemStart: Int
        let report: (String) -> Void

        init(bytes: Range<Int>, itemStart: Int, report: @escaping (String) -> Void) {
            self.bytes = bytes
            self.itemStart = itemStart
            self.report = report
            super.init(viewMode: .sourceAccurate)
        }

        override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
            let range = SwiftRefactoringFile.trimmed(node)
            guard bytes.contains(range.lowerBound), node.baseName.text.hasPrefix("$"),
                  node.baseName.text.dropFirst().allSatisfy(\.isNumber) else { return .visitChildren }
            // Fine when the closure that owns `$0` is inside the selection.
            var current: Syntax? = node.parent
            while let candidate = current {
                if candidate.is(ClosureExprSyntax.self) {
                    let closure = SwiftRefactoringFile.trimmed(candidate)
                    // Inside the selection, or around the statement: either way the name is in scope where it lands.
                    if closure.lowerBound >= bytes.lowerBound, closure.upperBound <= bytes.upperBound { return .visitChildren }
                    if closure.lowerBound < itemStart { return .visitChildren }
                    break
                }
                current = candidate.parent
            }
            report("The expression uses `\(node.baseName.text)`, which belongs to a closure.")
            return .visitChildren
        }
    }

    /// `try` and `await` that cover the expression have to come with it.
    private static func effects(above expression: ExprSyntax, within item: CodeBlockItemSyntax) -> Result<String, SwiftRefactoringFailure> {
        var hasTry = false
        var hasAwait = false
        var node = expression.parent
        while let current = node, current.id != item.id {
            if let tryExpr = current.as(TryExprSyntax.self) {
                if tryExpr.questionOrExclamationMark != nil {
                    return .failure(.init("The expression is under a `try?` or `try!`; extract the whole `try` expression."))
                }
                hasTry = true
            }
            if current.is(AwaitExprSyntax.self) { hasAwait = true }
            node = current.parent
        }
        var words = ""
        if hasTry, !expression.is(TryExprSyntax.self) { words += "try " }
        if hasAwait, !expression.is(AwaitExprSyntax.self), !(expression.as(TryExprSyntax.self)?.expression.is(AwaitExprSyntax.self) ?? false) {
            words += "await "
        }
        return .success(words)
    }

    /// Whether the statement is a body's only expression, which that body returns without saying so, and
    /// what saying so would take. Adding a statement before it makes `return` necessary.
    private enum ImplicitReturn {
        case notImplicit
        case returnsValue
        case returnsNothing
        case unknown
    }

    private static func implicitReturn(of item: CodeBlockItemSyntax) -> ImplicitReturn {
        guard let list = item.parent?.as(CodeBlockItemListSyntax.self), list.count == 1, item.item.is(ExprSyntax.self),
              let owner = list.parent else { return .notImplicit }
        if let closure = owner.as(ClosureExprSyntax.self) {
            if let explicit = closure.signature?.returnClause {
                let type = explicit.type
                let isVoid = type.as(IdentifierTypeSyntax.self).map { $0.name.text == "Void" } ?? false
                    || (type.as(TupleTypeSyntax.self)?.elements.isEmpty ?? false)
                return isVoid ? .returnsNothing : .returnsValue
            }
            return closureContext(closure)
        }
        if let block = owner.as(AccessorBlockSyntax.self), block.accessors.is(CodeBlockItemListSyntax.self) { return .returnsValue }
        guard let block = owner.as(CodeBlockSyntax.self), let parent = block.parent else { return .notImplicit }
        if let function = parent.as(FunctionDeclSyntax.self) {
            guard let clause = function.signature.returnClause else { return .returnsNothing }
            let type = clause.type
            let isVoid = type.as(IdentifierTypeSyntax.self).map { $0.name.text == "Void" } ?? false
                || (type.as(TupleTypeSyntax.self)?.elements.isEmpty ?? false)
            return isVoid ? .returnsNothing : .returnsValue
        }
        if let accessor = parent.as(AccessorDeclSyntax.self) {
            return accessor.accessorSpecifier.tokenKind == .keyword(.get) ? .returnsValue : .returnsNothing
        }
        return .notImplicit
    }

    /// A closure's result is known by the function it is passed to, for the common standard-library ones.
    private static func closureContext(_ closure: ClosureExprSyntax) -> ImplicitReturn {
        var node = closure.parent
        if let element = node?.as(LabeledExprSyntax.self) { node = element.parent?.parent }
        guard let call = node?.as(FunctionCallExprSyntax.self) else { return .unknown }
        let name = call.calledExpression.as(MemberAccessExprSyntax.self)?.declName.baseName.text
            ?? call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text ?? ""
        let producing: Set<String> = [
            "map", "compactMap", "flatMap", "filter", "reduce", "first", "firstIndex", "contains", "allSatisfy",
            "sorted", "sort", "min", "max", "drop", "prefix", "removeAll", "mapValues", "compactMapValues",
        ]
        if producing.contains(name) { return .returnsValue }
        if ["forEach", "async", "sync", "asyncAfter"].contains(name) { return .returnsNothing }
        return .unknown
    }

    // MARK: - Naming

    private static func usedNames(in file: SwiftRefactoringFile) -> Set<String> {
        var names = Set<String>()
        for token in file.tree.tokens(viewMode: .sourceAccurate) {
            if case .identifier(let text) = token.tokenKind { names.insert(text) }
        }
        return names
    }

    private static func name(for expression: ExprSyntax, avoiding used: Set<String>) -> String {
        func lowered(_ word: String) -> String {
            guard let first = word.first else { return "value" }
            return first.lowercased() + word.dropFirst()
        }
        var base = "value"
        if let call = expression.as(FunctionCallExprSyntax.self) {
            let callee = call.calledExpression
            if let member = callee.as(MemberAccessExprSyntax.self) { base = member.declName.baseName.text }
            else if let reference = callee.as(DeclReferenceExprSyntax.self) { base = reference.baseName.text }
        } else if let member = expression.as(MemberAccessExprSyntax.self) {
            base = member.declName.baseName.text
        } else if let reference = expression.as(DeclReferenceExprSyntax.self) {
            base = reference.baseName.text + "Value"
        } else if expression.is(StringLiteralExprSyntax.self) {
            base = "text"
        } else if expression.is(BooleanLiteralExprSyntax.self) {
            base = "flag"
        } else if expression.is(SubscriptCallExprSyntax.self) {
            base = "element"
        } else if expression.is(InfixOperatorExprSyntax.self) || expression.is(TernaryExprSyntax.self) {
            base = "result"
        }
        for prefix in ["get", "make", "create"] where base.hasPrefix(prefix) && base.dropFirst(prefix.count).first?.isUppercase == true {
            base = String(base.dropFirst(prefix.count))
        }
        var candidate = lowered(base)
        if !SwiftIdentifiers.isValid(candidate) { candidate = "value" }
        var suffix = 2
        let root = candidate
        while used.contains(candidate) {
            candidate = "\(root)\(suffix)"
            suffix += 1
        }
        return candidate
    }
}
