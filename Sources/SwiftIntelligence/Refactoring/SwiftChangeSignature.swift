import Foundation
import SwiftSyntax

/// One parameter of a function in the list a change signature produces: an existing one (by its place in the old
/// list) or a new one.
public struct SwiftSignatureParameter: Sendable, Equatable, Hashable, Codable {
    /// The place in the old parameter list, nil for a new parameter.
    public var oldIndex: Int?
    /// The argument label; `_` for none.
    public var label: String
    /// The name the body uses.
    public var name: String
    /// The type as written. An existing parameter keeps the type it has (attributes, `inout` and `...` included).
    public var type: String
    /// The default value as written, empty for none.
    public var defaultValue: String
    /// For a new parameter: the value every existing call passes. Empty to leave calls alone, which needs a default.
    public var callSiteValue: String

    public init(
        oldIndex: Int? = nil, label: String, name: String, type: String, defaultValue: String = "", callSiteValue: String = ""
    ) {
        self.oldIndex = oldIndex
        self.label = label
        self.name = name
        self.type = type
        self.defaultValue = defaultValue
        self.callSiteValue = callSiteValue
    }
}

/// What a call needs to know about an old parameter to match its arguments to it.
public struct SwiftOldParameterShape: Sendable, Equatable, Codable {
    /// The argument label; `_` for none.
    public var label: String
    public var hasDefault: Bool
    public var isVariadic: Bool

    public init(label: String, hasDefault: Bool, isVariadic: Bool) {
        self.label = label
        self.hasDefault = hasDefault
        self.isVariadic = isVariadic
    }
}

/// The parameter list a function should have afterwards.
public struct SwiftSignatureChange: Sendable, Equatable, Codable {
    public var parameters: [SwiftSignatureParameter]
    /// The old parameters as a call sees them, from ``SwiftChangeSignature/Subject/shape``. Not part of the JSON the form
    /// returns; the provider sets it. Without it no call is rewritten.
    public var oldShape: [SwiftOldParameterShape]

    public init(parameters: [SwiftSignatureParameter], oldShape: [SwiftOldParameterShape] = []) {
        self.parameters = parameters
        self.oldShape = oldShape
    }

    private enum CodingKeys: String, CodingKey { case parameters }

    public init(from decoder: Decoder) throws {
        parameters = try decoder.container(keyedBy: CodingKeys.self).decode([SwiftSignatureParameter].self, forKey: .parameters)
        oldShape = []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(parameters, forKey: .parameters)
    }

    /// The JSON the editor passes between the form and the provider.
    public var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(parameters), as: UTF8.self)) ?? "[]"
    }

    public init?(json: String?) {
        guard let json, let list = try? JSONDecoder().decode([SwiftSignatureParameter].self, from: Data(json.utf8)) else { return nil }
        self.init(parameters: list)
    }
}

/// Change a function's parameters — reorder, relabel, rename, add, remove — and bring its calls along.
///
/// The declarations (the function and its overrides and requirements) are rewritten exactly. A call is rewritten when
/// its arguments can be matched to the old parameters with certainty (labels, defaulted parameters left out,
/// variadics, trailing closures that stay last); any other call is reported back and left unchanged. A parameter
/// that is removed must be unused in the body, and a renamed one is renamed through the body.
public enum SwiftChangeSignature {
    public struct Subject: Sendable, Equatable {
        public let name: String
        /// UTF-8 range of the function's name token.
        public let nameBytes: Range<Int>
        public let parameters: [SwiftSignatureParameter]
        public let shape: [SwiftOldParameterShape]

        public var parameterCount: Int { parameters.count }
    }

    /// The function declaration whose name or parameter list holds `caret`.
    public static func subject(in text: String, caret: Int) -> Subject? {
        guard let file = SwiftRefactoringFile.load(text), let function = function(at: caret, file: file) else { return nil }
        let list = function.signature.parameterClause.parameters.enumerated().map { index, parameter in
            let names = names(of: parameter)
            return SwiftSignatureParameter(
                oldIndex: index, label: names.label, name: names.name,
                type: parameter.type.trimmedDescription + (parameter.ellipsis != nil ? "..." : ""),
                defaultValue: parameter.defaultValue?.value.trimmedDescription ?? ""
            )
        }
        let shape = function.signature.parameterClause.parameters.map { parameter in
            SwiftOldParameterShape(
                label: names(of: parameter).label == "_" ? "_" : names(of: parameter).label,
                hasDefault: parameter.defaultValue != nil, isVariadic: parameter.ellipsis != nil
            )
        }
        return Subject(name: function.name.text, nameBytes: SwiftRefactoringFile.trimmed(function.name), parameters: list, shape: shape)
    }

    public struct Outcome: Sendable {
        public var edits: [SwiftTextEdit]
        /// Name tokens whose call could not be rewritten safely, left unchanged.
        public var skipped: [Range<Int>]
    }

    /// Why `change` cannot be a parameter list at all, or nil. Independent of any file.
    public static func problem(in change: SwiftSignatureChange, oldCount: Int) -> String? {
        var labels = Set<String>()
        var names = Set<String>()
        var used = Set<Int>()
        for parameter in change.parameters {
            guard SwiftIdentifiers.isValid(parameter.name) else {
                return "'\(parameter.name)' is not a valid parameter name."
            }
            guard parameter.label == "_" || SwiftIdentifiers.isValid(parameter.label) || labelKeywordsAllowed.contains(parameter.label) else {
                return "'\(parameter.label)' is not a valid argument label."
            }
            if !names.insert(parameter.name).inserted { return "Two parameters are called '\(parameter.name)'." }
            if parameter.label != "_", !labels.insert(parameter.label).inserted { return "Two parameters have the label '\(parameter.label)'." }
            if let index = parameter.oldIndex {
                guard (0 ..< oldCount).contains(index), used.insert(index).inserted else { return "The parameter list is inconsistent." }
            } else {
                if parameter.type.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the new parameter '\(parameter.name)' a type." }
                if parameter.defaultValue.trimmingCharacters(in: .whitespaces).isEmpty,
                   parameter.callSiteValue.trimmingCharacters(in: .whitespaces).isEmpty {
                    return "The new parameter '\(parameter.name)' needs a default value or a value for the existing calls."
                }
            }
        }
        return nil
    }

    /// Words that are keywords but can still be argument labels (`in`, `for`, `with`…): anything but a few that read
    /// ambiguously.
    private static let labelKeywordsAllowed: Set<String> = ["in", "for", "is", "as", "where", "if", "do", "case", "default", "repeat", "while"]

    /// Edits for the declarations and calls named at `nameBytes` in `text`. `primary` is the name token of the
    /// declaration the user asked about (when it is in this file): only that declaration's internal names change.
    public static func edits(
        in text: String, nameBytes: [Range<Int>], primary: Range<Int>?, oldCount: Int, change: SwiftSignatureChange
    ) -> Result<Outcome, SwiftRefactoringFailure> {
        if let problem = problem(in: change, oldCount: oldCount) { return .failure(.init(problem)) }
        guard let file = SwiftRefactoringFile.load(text) else {
            return .failure(.init("The file has syntax errors; fix them before refactoring."))
        }
        var edits: [SwiftTextEdit] = []
        var skipped: [Range<Int>] = []
        for name in nameBytes.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            guard let token = file.tree.token(at: AbsolutePosition(utf8Offset: name.lowerBound)) else { continue }
            if let function = token.parent?.as(FunctionDeclSyntax.self), function.name.id == token.id {
                switch declarationEdits(function, isPrimary: name == primary, oldCount: oldCount, change: change, file: file) {
                case .failure(let failure): return .failure(failure)
                case .success(let more): edits += more
                }
            } else if let call = callExpression(whoseNameIs: token) {
                switch callEdit(call, oldCount: oldCount, change: change, file: file) {
                case .unchanged: break
                case .edit(let edit): edits.append(edit)
                case .unsure: skipped.append(name)
                }
            } else {
                skipped.append(name)
            }
        }
        return .success(Outcome(edits: edits, skipped: skipped))
    }

    // MARK: - Declarations

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

    private static func names(of parameter: FunctionParameterSyntax) -> (label: String, name: String) {
        let first = parameter.firstName.text
        let second = parameter.secondName?.text
        return (first, second ?? first)
    }

    private static func declarationEdits(
        _ function: FunctionDeclSyntax, isPrimary: Bool, oldCount: Int, change: SwiftSignatureChange, file: SwiftRefactoringFile
    ) -> Result<[SwiftTextEdit], SwiftRefactoringFailure> {
        let clause = function.signature.parameterClause
        let old = Array(clause.parameters)
        guard old.count == oldCount else {
            return .failure(.init("An overload with a different number of parameters shares this name; change them one at a time."))
        }
        var edits: [SwiftTextEdit] = []
        let references = file.references

        // A removed parameter must not be read in the body.
        let kept = Set(change.parameters.compactMap(\.oldIndex))
        for (index, parameter) in old.enumerated() where !kept.contains(index) {
            let local = SwiftRefactoringFile.trimmed(parameter.secondName ?? parameter.firstName)
            if references.contains(where: { reference in
                if case .local(let declared, _) = reference.resolution { return declared == local }
                return false
            }) {
                return .failure(.init("`\((parameter.secondName ?? parameter.firstName).text)` is used in the body, so it cannot be removed."))
            }
        }

        var rendered: [String] = []
        for parameter in change.parameters {
            if let index = parameter.oldIndex {
                let oldParameter = old[index]
                let oldName = names(of: oldParameter).name
                // Only the declaration asked about takes the new internal name; an override keeps its own.
                let name = isPrimary ? parameter.name : oldName
                rendered.append(render(parameter, old: oldParameter, name: name))
                if isPrimary, parameter.name != oldName {
                    let local = SwiftRefactoringFile.trimmed(oldParameter.secondName ?? oldParameter.firstName)
                    for reference in references {
                        if case .local(let declared, _) = reference.resolution, declared == local {
                            edits.append(SwiftTextEdit(bytes: reference.bytes, replacement: parameter.name))
                        }
                    }
                }
            } else {
                rendered.append(render(parameter, old: nil, name: parameter.name))
            }
        }

        let inner = SwiftRefactoringFile.trimmed(clause.leftParen).upperBound ..< SwiftRefactoringFile.trimmed(clause.rightParen).lowerBound
        let original = file.string(inner)
        let separator = original.contains("\n") ? ",\n" + (indentation(ofFirstLineIn: original) ?? "    ") : ", "
        var text = rendered.joined(separator: separator)
        if original.contains("\n"), !rendered.isEmpty {
            // Keep the closing parenthesis where it was: on its own line when the list was spread over lines.
            let tail = original.reversed().prefix { $0 == " " || $0 == "\t" || $0 == "\n" }
            text = "\n" + (indentation(ofFirstLineIn: original) ?? "    ") + text + String(tail.reversed())
        }
        edits.append(SwiftTextEdit(bytes: inner, replacement: text))
        return .success(edits)
    }

    /// `label name: Type = default`, reusing what the old declaration wrote for the parts the form does not edit.
    private static func render(_ parameter: SwiftSignatureParameter, old: FunctionParameterSyntax?, name: String) -> String {
        let label = parameter.label
        let naming: String
        if label == "_" { naming = "_ \(name)" } else if label == name { naming = label } else { naming = "\(label) \(name)" }
        var prefix = ""
        let type: String
        if let old {
            if !old.attributes.isEmpty { prefix += old.attributes.trimmedDescription + " " }
            if !old.modifiers.isEmpty { prefix += old.modifiers.trimmedDescription + " " }
            type = old.type.trimmedDescription + (old.ellipsis != nil ? "..." : "")
        } else {
            type = parameter.type.trimmingCharacters(in: .whitespaces)
        }
        let value = parameter.defaultValue.trimmingCharacters(in: .whitespaces)
        return prefix + naming + ": " + type + (value.isEmpty ? "" : " = " + value)
    }

    private static func indentation(ofFirstLineIn text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            if indent.count < line.count { return String(indent) }
        }
        return nil
    }

    // MARK: - Calls

    private enum CallResult {
        case unchanged
        case edit(SwiftTextEdit)
        case unsure
    }

    /// The call whose callee ends in the identifier `token` (`f(…)`, `a.f(…)`, `f(…) { }`).
    private static func callExpression(whoseNameIs token: TokenSyntax) -> FunctionCallExprSyntax? {
        guard let reference = token.parent?.as(DeclReferenceExprSyntax.self) else { return nil }
        var callee: ExprSyntax = ExprSyntax(reference)
        if let access = reference.parent?.as(MemberAccessExprSyntax.self), access.declName.id == reference.id { callee = ExprSyntax(access) }
        if let call = callee.parent?.as(FunctionCallExprSyntax.self), call.calledExpression.id == callee.id { return call }
        return nil
    }

    private struct OldParameter {
        let label: String?
        let hasDefault: Bool
        let isVariadic: Bool
    }

    /// Which arguments go to which old parameter, or nil when the call cannot be read with certainty.
    private static func match(_ arguments: [LabeledExprSyntax], to old: [OldParameter], limit: Int) -> [Int: [LabeledExprSyntax]]? {
        var result: [Int: [LabeledExprSyntax]] = [:]
        var position = 0
        var variadic: Int?
        for argument in arguments {
            if let current = variadic, argument.label == nil {
                result[current, default: []].append(argument)
                continue
            }
            variadic = nil
            var assigned = false
            while position < limit {
                let parameter = old[position]
                let matches = argument.label?.text == parameter.label
                if matches {
                    result[position, default: []].append(argument)
                    if parameter.isVariadic { variadic = position }
                    position += 1
                    assigned = true
                    break
                }
                guard parameter.hasDefault || parameter.isVariadic else { return nil }
                position += 1
            }
            if !assigned { return nil }
        }
        return result
    }

    private static func callEdit(
        _ call: FunctionCallExprSyntax, oldCount: Int, change: SwiftSignatureChange, file: SwiftRefactoringFile
    ) -> CallResult {
        guard let layout = oldLayout(of: change, oldCount: oldCount) else { return .unsure }
        let trailing = (call.trailingClosure == nil ? 0 : 1) + call.additionalTrailingClosures.count
        let parenthesized = Array(call.arguments)
        let paramsForParens = oldCount - trailing
        guard paramsForParens >= 0 else { return .unsure }
        guard let matched = match(parenthesized, to: layout, limit: paramsForParens) else { return .unsure }
        // A call that leaves out a required parameter does not compile today; do not guess what it meant.
        for index in 0 ..< paramsForParens where matched[index] == nil && !layout[index].hasDefault && !layout[index].isVariadic {
            return .unsure
        }

        if trailing > 0 {
            // The trailing closures are the last parameters; they must stay the last, in the same order.
            let lastOld = (oldCount - trailing ..< oldCount).map { $0 }
            let lastNew = change.parameters.suffix(trailing).compactMap(\.oldIndex)
            guard lastNew == lastOld, change.parameters.suffix(trailing).count == trailing else { return .unsure }
            // The parameters the parentheses hold: anything new before them is fine, a call with no parentheses cannot gain any.
        }

        // The argument list the new signature gives this call.
        var pieces: [String] = []
        for parameter in change.parameters.dropLast(trailing) {
            if let index = parameter.oldIndex {
                guard let arguments = matched[index] else { continue }   // left out, so defaulted: stays out
                for (offset, argument) in arguments.enumerated() {
                    let label = offset == 0 && parameter.label != "_" ? parameter.label + ": " : ""
                    pieces.append(label + argument.expression.trimmedDescription)
                }
            } else {
                let value = parameter.callSiteValue.trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty else { continue }
                pieces.append((parameter.label == "_" ? "" : parameter.label + ": ") + value)
            }
        }
        // Labels of additional trailing closures follow their parameters.
        var additional: [SwiftTextEdit] = []
        if trailing > 1 {
            for (offset, closure) in call.additionalTrailingClosures.enumerated() {
                let parameter = change.parameters[change.parameters.count - trailing + 1 + offset]
                if closure.label.text != parameter.label, parameter.label != "_" {
                    additional.append(SwiftTextEdit(bytes: SwiftRefactoringFile.trimmed(closure.label), replacement: parameter.label))
                }
            }
        }

        let newText = pieces.joined(separator: ", ")
        if let left = call.leftParen, let right = call.rightParen {
            let inner = SwiftRefactoringFile.trimmed(left).upperBound ..< SwiftRefactoringFile.trimmed(right).lowerBound
            let multiline = file.string(inner).contains("\n")
            let text = multiline && pieces.count > 1 ? joinedOnLines(pieces, like: file.string(inner)) : newText
            if text == file.string(inner), additional.isEmpty { return .unchanged }
            if !additional.isEmpty { return .unsure }   // two edits for one call: report it, do not guess
            return .edit(SwiftTextEdit(bytes: inner, replacement: text))
        }
        // `f { … }`: no parentheses to put an argument in.
        return pieces.isEmpty && additional.isEmpty ? .unchanged : .unsure
    }

    private static func joinedOnLines(_ pieces: [String], like original: String) -> String {
        let indent = indentation(ofFirstLineIn: original) ?? "    "
        let tail = String(original.reversed().prefix { $0 == " " || $0 == "\t" || $0 == "\n" }.reversed())
        return "\n" + indent + pieces.joined(separator: ",\n" + indent) + tail
    }

    /// The old parameters' call-side shape (label, defaulted, variadic) from the change's record of them.
    private static func oldLayout(of change: SwiftSignatureChange, oldCount: Int) -> [OldParameter]? {
        let record = change.oldShape
        guard record.count == oldCount else { return nil }
        return record.map { OldParameter(label: $0.label == "_" ? nil : $0.label, hasDefault: $0.hasDefault, isVariadic: $0.isVariadic) }
    }
}
