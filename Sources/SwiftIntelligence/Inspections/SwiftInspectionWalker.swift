import Foundation
import SwiftSyntax

/// One pass over a file's tree that runs every enabled rule on the nodes it cares about.
///
/// The tree is the operator-folded one (`SwiftInspectionPipeline`): the parser leaves `a + b == c` as a flat
/// sequence, and a rule that asks "is this the left side of `==`?" needs the precedence applied. Folding
/// keeps every token and trivia, so byte offsets are those of the source.
///
/// A rule here reports something the compiler does not, and only when it can be sure from the syntax:
/// where a fix would be wrong for some type (`count == 0` on a type with no `isEmpty`), the rule says so in
/// its message rather than guess, and where it cannot be sure of the fix it offers none.
final class SwiftInspectionWalker: SyntaxVisitor {
    let enabled: Set<SwiftInspectionRule>
    let limits: SwiftInspectionLimits
    let utf8: [UInt8]
    private(set) var findings: [SwiftInspection] = []
    /// Whether a type in this file has a `count` and no `isEmpty`: `x.count > 0` may then be about that type,
    /// where `isEmpty` does not compile. Set when the walk enters the file.
    private(set) var declaresCountWithoutIsEmpty = false
    /// How many times each identifier is written in the file, declarations included. Set when the walk enters the
    /// file, only while a rule that reads it is on.
    private(set) var identifierCounts: [String: Int] = [:]

    init(enabled: Set<SwiftInspectionRule>, limits: SwiftInspectionLimits, utf8: [UInt8]) {
        self.enabled = enabled
        self.limits = limits
        self.utf8 = utf8
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - Reporting

    func bytes(_ node: some SyntaxProtocol) -> Range<Int> {
        node.positionAfterSkippingLeadingTrivia.utf8Offset ..< node.endPositionBeforeTrailingTrivia.utf8Offset
    }

    func report(_ rule: SwiftInspectionRule, _ message: String, _ range: Range<Int>, fixes: [SwiftInspectionFix] = []) {
        findings.append(SwiftInspection(
            id: rule.code, message: message, severity: rule.defaultSeverity, bytes: range, fixes: fixes
        ))
    }

    func report(_ rule: SwiftInspectionRule, _ message: String, at node: some SyntaxProtocol, fixes: [SwiftInspectionFix] = []) {
        report(rule, message, bytes(node), fixes: fixes)
    }

    func fix(_ title: String, _ edits: SwiftInspectionFix.Edit...) -> SwiftInspectionFix {
        SwiftInspectionFix(title: title, edits: edits)
    }

    func edit(_ range: Range<Int>, _ replacement: String) -> SwiftInspectionFix.Edit {
        SwiftInspectionFix.Edit(bytes: range, replacement: replacement)
    }

    func isOn(_ rule: SwiftInspectionRule) -> Bool { enabled.contains(rule) }

    /// Lines a byte range spans.
    func lineCount(of range: Range<Int>) -> Int {
        let lower = max(range.lowerBound, 0)
        let upper = min(range.upperBound, utf8.count)
        guard lower < upper else { return 1 }
        return 1 + utf8[lower ..< upper].reduce(0) { $0 + ($1 == UInt8(ascii: "\n") ? 1 : 0) }
    }

    // MARK: - Shared syntax questions

    /// Whether evaluating the expression twice can differ from evaluating it once: a call, an `await`, a
    /// `try`, a closure or an assignment anywhere in it.
    func isPure(_ node: some SyntaxProtocol) -> Bool {
        let visitor = PurityVisitor()
        visitor.walk(node)
        return visitor.isPure
    }

    func containsClosure(_ node: some SyntaxProtocol) -> Bool {
        let visitor = ClosureFinder()
        visitor.walk(node)
        return visitor.found
    }

    /// Whether optional chaining appears in the postfix chain of `expr` (`a?.b`, `a?.b.c`). A rewrite that
    /// drops the chain changes what `nil` means.
    func hasOptionalChaining(_ expr: ExprSyntax) -> Bool {
        var current: ExprSyntax? = expr
        while let node = current {
            if node.is(OptionalChainingExprSyntax.self) { return true }
            if let member = node.as(MemberAccessExprSyntax.self) { current = member.base; continue }
            if let call = node.as(FunctionCallExprSyntax.self) { current = call.calledExpression; continue }
            if let subscriptCall = node.as(SubscriptCallExprSyntax.self) { current = subscriptCall.calledExpression; continue }
            if let force = node.as(ForceUnwrapExprSyntax.self) { current = force.expression; continue }
            return false
        }
        return false
    }

    func operatorText(of node: InfixOperatorExprSyntax) -> String? {
        node.operator.as(BinaryOperatorExprSyntax.self)?.operator.text
    }

    func isIntegerLiteral(_ expr: ExprSyntax, _ value: String) -> Bool {
        expr.as(IntegerLiteralExprSyntax.self)?.literal.text == value
    }

    func hasComment(in block: CodeBlockSyntax) -> Bool {
        block.leftBrace.trailingTrivia.contains { $0.isComment }
            || block.rightBrace.leadingTrivia.contains { $0.isComment }
            || block.statements.leadingTrivia.contains { $0.isComment }
    }

    /// Whether `node` is the called expression of its parent call (`x.first()` rather than `x.first`).
    func isCalled(_ node: some ExprSyntaxProtocol) -> Bool {
        guard let call = node.parent?.as(FunctionCallExprSyntax.self) else { return false }
        return call.calledExpression.id == node.id
    }

    // MARK: - Dispatch

    override func visit(_ node: SourceFileSyntax) -> SyntaxVisitorContinueKind {
        if isOn(.unusedPrivateMember) { identifierCounts = Self.countIdentifiers(in: node) }
        if isOn(.countIsZero) {
            let finder = CountWithoutIsEmptyFinder()
            finder.walk(node)
            declaresCountWithoutIsEmpty = finder.found
        }
        return .visitChildren
    }

    override func visit(_ node: ForceUnwrapExprSyntax) -> SyntaxVisitorContinueKind {
        checkForceUnwrap(node)
        return .visitChildren
    }

    override func visit(_ node: TryExprSyntax) -> SyntaxVisitorContinueKind {
        checkForceTry(node)
        return .visitChildren
    }

    override func visit(_ node: AsExprSyntax) -> SyntaxVisitorContinueKind {
        checkForceCast(node)
        return .visitChildren
    }

    override func visit(_ node: CatchClauseSyntax) -> SyntaxVisitorContinueKind {
        checkEmptyCatch(node)
        return .visitChildren
    }

    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        checkIdenticalOperands(node)
        checkCountIsZero(node)
        checkFirstWhereNil(node)
        return .visitChildren
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        checkFilterFirst(node)
        checkSortedFirst(node)
        return .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        checkLeftoverPrint(node)
        checkExplicitInit(node)
        return .visitChildren
    }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        checkUnusedClosureParameters(node)
        return .visitChildren
    }

    override func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind {
        checkRedundantReturn(node)
        return .visitChildren
    }

    override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
        checkDuplicateConditions(node)
        checkRedundantParentheses(in: node.conditions)
        if node.elseKeyword == nil { checkEmptyBody(node.body, keyword: node.ifKeyword) }
        return .visitChildren
    }

    override func visit(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind {
        checkRedundantParentheses(in: node.conditions)
        return .visitChildren
    }

    override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind {
        checkRedundantParentheses(in: node.conditions)
        return .visitChildren
    }

    override func visit(_ node: SwitchExprSyntax) -> SyntaxVisitorContinueKind {
        checkRedundantParentheses(around: node.subject)
        return .visitChildren
    }

    override func visit(_ node: SwitchCaseSyntax) -> SyntaxVisitorContinueKind {
        checkUnneededBreak(node)
        return .visitChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        checkUnusedPrivate(variable: node)
        checkDelegateNotWeak(node)
        checkRedundantOptionalInitialization(node)
        checkMemberNameCase(variable: node)
        return .visitChildren
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        checkUnusedPrivate(function: node)
        checkRedundantVoidReturn(node)
        checkMemberNameCase(function: node)
        checkMetrics(name: node.name, parameters: node.signature.parameterClause.parameters.count, body: node.body)
        return .visitChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        checkMetrics(name: node.initKeyword, parameters: node.signature.parameterClause.parameters.count, body: node.body)
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        checkUnusedPrivate(type: node, name: node.name, modifiers: node.modifiers, attributes: node.attributes)
        checkTypeName(node.name)
        return .visitChildren
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        checkUnusedPrivate(type: node, name: node.name, modifiers: node.modifiers, attributes: node.attributes)
        checkTypeName(node.name)
        return .visitChildren
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        checkUnusedPrivate(type: node, name: node.name, modifiers: node.modifiers, attributes: node.attributes)
        checkTypeName(node.name)
        return .visitChildren
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        checkUnusedPrivate(type: node, name: node.name, modifiers: node.modifiers, attributes: node.attributes)
        checkTypeName(node.name)
        return .visitChildren
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        checkUnusedPrivate(type: node, name: node.name, modifiers: node.modifiers, attributes: node.attributes)
        checkTypeName(node.name)
        return .visitChildren
    }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        checkUnusedPrivate(type: node, name: node.name, modifiers: node.modifiers, attributes: node.attributes)
        checkTypeName(node.name)
        return .visitChildren
    }
}

// MARK: - Small visitors

private final class PurityVisitor: SyntaxVisitor {
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

/// A type declared in the file that has a member named `count` and none named `isEmpty` (its extensions in
/// the same file count towards it, by name).
private final class CountWithoutIsEmptyFinder: SyntaxVisitor {
    private var members: [String: Set<String>] = [:]

    init() { super.init(viewMode: .sourceAccurate) }

    var found: Bool { members.values.contains { $0.contains("count") && !$0.contains("isEmpty") } }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { record(node.name.text, node.memberBlock) }
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { record(node.name.text, node.memberBlock) }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { record(node.name.text, node.memberBlock) }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind { record(node.name.text, node.memberBlock) }
    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind { record(node.name.text, node.memberBlock) }
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node.extendedType.trimmedDescription, node.memberBlock)
    }

    private func record(_ type: String, _ block: MemberBlockSyntax) -> SyntaxVisitorContinueKind {
        for member in block.members {
            if let variable = member.decl.as(VariableDeclSyntax.self) {
                for binding in variable.bindings {
                    if let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text { members[type, default: []].insert(name) }
                }
            } else if let function = member.decl.as(FunctionDeclSyntax.self) {
                members[type, default: []].insert(function.name.text)
            }
        }
        return .visitChildren
    }
}

private final class ClosureFinder: SyntaxVisitor {
    var found = false

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        found = true
        return .skipChildren
    }
}
