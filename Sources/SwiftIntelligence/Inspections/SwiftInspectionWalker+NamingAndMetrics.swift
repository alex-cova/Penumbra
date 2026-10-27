import Foundation
import SwiftSyntax

// Naming conventions and size metrics.
extension SwiftInspectionWalker {
    /// A type whose name starts with a lowercase letter. A backticked or underscore-led name is left alone.
    func checkTypeName(_ name: TokenSyntax) {
        guard isOn(.typeNameCase), let first = name.text.first, first.isLetter, first.isLowercase else { return }
        report(.typeNameCase, "Type name `\(name.text)` should start with an uppercase letter.", at: name)
    }

    /// A property or function whose name starts with an uppercase letter. An all-capitals name (`URL`, `MAX`)
    /// is an acronym or a constant and is allowed.
    func checkMemberNameCase(variable node: VariableDeclSyntax) {
        guard isOn(.memberNameCase) else { return }
        for binding in node.bindings {
            if let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier { checkMemberName(name) }
        }
    }

    func checkMemberNameCase(function node: FunctionDeclSyntax) {
        guard isOn(.memberNameCase) else { return }
        checkMemberName(node.name)
    }

    private func checkMemberName(_ name: TokenSyntax) {
        let text = name.text
        guard let first = text.first, first.isLetter, first.isUppercase, text.contains(where: \.isLowercase) else { return }
        report(.memberNameCase, "`\(text)` should start with a lowercase letter.", at: name)
    }

    /// Function length, parameter count and cyclomatic complexity, against the limits in the options.
    func checkMetrics(name: TokenSyntax, parameters: Int, body: CodeBlockSyntax?) {
        let label = name.text
        if isOn(.manyParameters), parameters > limits.parameters {
            report(.manyParameters, "`\(label)` has \(parameters) parameters (limit \(limits.parameters)).", at: name)
        }
        guard let body else { return }
        if isOn(.longFunction) {
            let lines = lineCount(of: bytes(body))
            if lines > limits.functionLines {
                report(.longFunction, "`\(label)` is \(lines) lines long (limit \(limits.functionLines)).", at: name)
            }
        }
        if isOn(.highComplexity) {
            let counter = ComplexityCounter()
            counter.walk(body)
            let complexity = counter.complexity
            if complexity > limits.complexity {
                report(.highComplexity, "`\(label)` has a cyclomatic complexity of \(complexity) (limit \(limits.complexity)).", at: name)
            }
        }
    }
}

/// 1 plus the decision points in a body: branches, loops, `case`s, `catch`es, `&&`, `||`, `??` and `?:`.
/// A nested function is its own function and is not counted here.
private final class ComplexityCounter: SyntaxVisitor {
    private(set) var complexity = 1

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind { count() }
    override func visit(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind { count() }
    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind { count() }
    override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind { count() }
    override func visit(_ node: RepeatStmtSyntax) -> SyntaxVisitorContinueKind { count() }
    override func visit(_ node: CatchClauseSyntax) -> SyntaxVisitorContinueKind { count() }
    override func visit(_ node: TernaryExprSyntax) -> SyntaxVisitorContinueKind { count() }

    override func visit(_ node: SwitchCaseSyntax) -> SyntaxVisitorContinueKind {
        if case .case = node.label { return count() }
        return .visitChildren
    }

    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        if let op = node.operator.as(BinaryOperatorExprSyntax.self)?.operator.text, ["&&", "||", "??"].contains(op) {
            return count()
        }
        return .visitChildren
    }

    private func count() -> SyntaxVisitorContinueKind {
        complexity += 1
        return .visitChildren
    }
}
