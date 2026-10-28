import Foundation
import SwiftSyntax

/// What to change in a function's parameter list.
public struct SwiftSignatureChange: Sendable, Equatable {
    /// A parameter to append; a default value keeps every call valid without touching it.
    public var addName = ""
    public var addType = ""
    public var addDefault = ""
    /// Drop the last parameter and its argument at each call.
    public var removeLast = false

    public init(addName: String = "", addType: String = "", addDefault: String = "", removeLast: Bool = false) {
        self.addName = addName
        self.addType = addType
        self.addDefault = addDefault
        self.removeLast = removeLast
    }

    public var addsParameter: Bool { !addName.isEmpty || !addType.isEmpty || !addDefault.isEmpty }
}

/// Add a defaulted parameter to a function, or remove its last one, and bring the calls along.
///
/// The declaration and its overrides are edited exactly. A call is edited only when its arguments are the whole
/// parameter list (no defaulted parameter left out, no trailing closure); any other call is reported back as
/// one the caller should look at, and left unchanged.
public enum SwiftChangeSignature {
    public struct Subject: Sendable, Equatable {
        public let name: String
        public let parameterCount: Int
        public let lastParameter: String?
        /// UTF-8 range of the function's name token.
        public let nameBytes: Range<Int>
    }

    /// The function declaration whose name or parameter list holds `caret`.
    public static func subject(in text: String, caret: Int) -> Subject? {
        guard let file = SwiftRefactoringFile.load(text), let function = function(at: caret, file: file) else { return nil }
        let parameters = function.signature.parameterClause.parameters
        return Subject(
            name: function.name.text, parameterCount: parameters.count,
            lastParameter: parameters.last.map { ($0.secondName ?? $0.firstName).text },
            nameBytes: SwiftRefactoringFile.trimmed(function.name)
        )
    }

    public struct Outcome: Sendable {
        public var edits: [SwiftTextEdit]
        /// Name tokens whose call could not be rewritten safely, left unchanged.
        public var skipped: [Range<Int>]
    }

    /// Edits for the declarations and calls named at `nameBytes` in `text`.
    public static func edits(
        in text: String, nameBytes: [Range<Int>], parameterCount: Int, change: SwiftSignatureChange
    ) -> Result<Outcome, SwiftRefactoringFailure> {
        guard let file = SwiftRefactoringFile.load(text) else {
            return .failure(.init("The file has syntax errors; fix them before refactoring."))
        }
        var edits: [SwiftTextEdit] = []
        var skipped: [Range<Int>] = []
        let references = SwiftSyntaxScopes.references(in: file.document)
        for name in nameBytes.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            guard let token = file.tree.token(at: AbsolutePosition(utf8Offset: name.lowerBound)) else { continue }
            if let function = token.parent?.as(FunctionDeclSyntax.self), function.name.id == token.id {
                switch declarationEdits(function, parameterCount: parameterCount, change: change, file: file, references: references) {
                case .failure(let failure): return .failure(failure)
                case .success(let more): edits += more
                }
            } else if let call = callExpression(whoseNameIs: token) {
                if change.removeLast {
                    if let edit = removalEdit(call, parameterCount: parameterCount, file: file) { edits.append(edit) } else { skipped.append(name) }
                } else if !isFullCall(call, parameterCount: parameterCount) && change.addsParameter {
                    // A default makes the call valid as it is.
                    continue
                }
            } else {
                skipped.append(name)
            }
        }
        return .success(Outcome(edits: edits, skipped: skipped))
    }

    // MARK: - Declaration

    private static func function(at caret: Int, file: SwiftRefactoringFile) -> FunctionDeclSyntax? {
        guard let token = file.tree.token(at: AbsolutePosition(utf8Offset: min(max(caret, 0), max(file.utf8.count - 1, 0)))) else { return nil }
        var node: Syntax? = Syntax(token)
        while let current = node {
            if let function = current.as(FunctionDeclSyntax.self) {
                // The header only: not a nested function's or closure's own text in the body.
                let header = SwiftRefactoringFile.trimmed(function.name).lowerBound ..< SwiftRefactoringFile.trimmed(function.signature).upperBound
                return header.contains(caret) || header.upperBound == caret ? function : nil
            }
            if current.is(CodeBlockSyntax.self) || current.is(MemberBlockSyntax.self) { return nil }
            node = current.parent
        }
        return nil
    }

    private static func declarationEdits(
        _ function: FunctionDeclSyntax, parameterCount: Int, change: SwiftSignatureChange, file: SwiftRefactoringFile,
        references: [SwiftSyntaxScopes.Reference]
    ) -> Result<[SwiftTextEdit], SwiftRefactoringFailure> {
        let clause = function.signature.parameterClause
        let parameters = clause.parameters
        guard parameters.count == parameterCount else {
            return .failure(.init("An overload with a different number of parameters shares this name; change them one at a time."))
        }
        if change.removeLast {
            guard let last = parameters.last else { return .failure(.init("The function has no parameters.")) }
            let local = SwiftRefactoringFile.trimmed(last.secondName ?? last.firstName)
            if references.contains(where: { reference in
                if case .local(let declared, _) = reference.resolution { return declared == local }
                return false
            }) {
                return .failure(.init("`\((last.secondName ?? last.firstName).text)` is used in the body, so it cannot be removed."))
            }
            let range: Range<Int>
            if parameters.count == 1 {
                range = SwiftRefactoringFile.trimmed(last)
            } else {
                let previous = parameters[parameters.index(before: parameters.index(before: parameters.endIndex))]
                range = commaStart(after: previous.trailingComma, else: SwiftRefactoringFile.trimmed(previous).upperBound)
                    ..< SwiftRefactoringFile.trimmed(last).upperBound
            }
            return .success([SwiftTextEdit(bytes: range, replacement: "")])
        }
        var existing = Set<String>()
        for parameter in parameters {
            existing.insert(parameter.firstName.text)
            if let second = parameter.secondName { existing.insert(second.text) }
        }
        guard !existing.contains(change.addName) else { return .failure(.init("A parameter called `\(change.addName)` already exists.")) }
        let new = "\(change.addName): \(change.addType) = \(change.addDefault)"
        if let last = parameters.last {
            // After a variadic parameter a defaulted one is still fine, but a trailing closure label would move.
            let end = SwiftRefactoringFile.trimmed(last).upperBound
            return .success([SwiftTextEdit(bytes: end ..< end, replacement: ", " + new)])
        }
        let right = SwiftRefactoringFile.trimmed(clause.rightParen).lowerBound
        return .success([SwiftTextEdit(bytes: right ..< right, replacement: new)])
    }

    // MARK: - Calls

    /// The call whose callee ends in the identifier `token` (`f(…)`, `a.f(…)`, `f(…) { }`).
    private static func callExpression(whoseNameIs token: TokenSyntax) -> FunctionCallExprSyntax? {
        guard let reference = token.parent?.as(DeclReferenceExprSyntax.self) else { return nil }
        var callee: ExprSyntax = ExprSyntax(reference)
        if let access = reference.parent?.as(MemberAccessExprSyntax.self), access.declName.id == reference.id { callee = ExprSyntax(access) }
        if let call = callee.parent?.as(FunctionCallExprSyntax.self), call.calledExpression.id == callee.id { return call }
        return nil
    }

    private static func isFullCall(_ call: FunctionCallExprSyntax, parameterCount: Int) -> Bool {
        call.arguments.count == parameterCount && call.trailingClosure == nil && call.additionalTrailingClosures.isEmpty
    }

    private static func removalEdit(_ call: FunctionCallExprSyntax, parameterCount: Int, file: SwiftRefactoringFile) -> SwiftTextEdit? {
        guard isFullCall(call, parameterCount: parameterCount), let last = call.arguments.last else { return nil }
        if call.arguments.count == 1 { return SwiftTextEdit(bytes: SwiftRefactoringFile.trimmed(last), replacement: "") }
        let previous = call.arguments[call.arguments.index(before: call.arguments.index(before: call.arguments.endIndex))]
        return SwiftTextEdit(
            bytes: commaStart(after: previous.trailingComma, else: SwiftRefactoringFile.trimmed(previous).upperBound)
                ..< SwiftRefactoringFile.trimmed(last).upperBound,
            replacement: ""
        )
    }

    /// Where the comma that separates an element from the next one starts, so it goes with the element after it.
    private static func commaStart(after comma: TokenSyntax?, else fallback: Int) -> Int {
        comma?.positionAfterSkippingLeadingTrivia.utf8Offset ?? fallback
    }
}
