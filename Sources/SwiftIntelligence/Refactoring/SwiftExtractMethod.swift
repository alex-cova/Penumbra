import Foundation
import SwiftSyntax

/// Extract the selected statements or the one selected expression into a new private method of the
/// same type, after the enclosing function.
///
/// The selection is a run of whole statements in one block (leading and trailing whitespace is
/// fine) or exactly one expression. What the selection reads from before it becomes parameters
/// (`_ x: Type`, `inout` when the selection writes the variable, passes a member through it or
/// takes it with `&`, and passed as `&x`); at most one declaration it leaves behind becomes the
/// return value, bound with the same `let`/`var`. A `try` or `await` the selection carries makes
/// the method `throws`/`async` and the call `try`/`await`. Anything the syntax cannot prove safe —
/// a `return`, `break`, `continue` or `fallthrough` that leaves the selection, a top-level `defer`,
/// a closure, `$0` or an implicit name, a local function or type, a generic parameter in a type,
/// an untypable input, an existing name — is refused instead.
public enum SwiftExtractMethod {
    /// A name for the new method that nothing in the file already takes, or nil when the selection
    /// is not something to extract.
    public static func suggestedName(in text: String, selection: Range<Int>) -> String? {
        guard let file = SwiftRefactoringFile.load(text) else { return nil }
        let trimmed = file.trimmedBytes(selection)
        guard !trimmed.isEmpty else { return nil }
        let used = SwiftRefactoringNaming.usedNames(in: file)
        if let run = file.statementRun(exactly: selection), let first = run.first {
            switch first.item {
            case .expr(let expression):
                return SwiftRefactoringNaming.name(for: expression, avoiding: used)
            case .decl(let decl):
                if let variable = decl.as(VariableDeclSyntax.self),
                   let initializer = variable.bindings.first?.initializer?.value {
                    return SwiftRefactoringNaming.name(for: initializer, avoiding: used)
                }
            case .stmt:
                break
            }
            if let called = firstCall(in: run, file: file) {
                return SwiftRefactoringNaming.name(for: called, avoiding: used)
            }
            return numbered("extracted", avoiding: used)
        }
        if let expression = file.expression(exactly: trimmed) {
            return SwiftRefactoringNaming.name(for: expression, avoiding: used)
        }
        return nil
    }

    /// The first call in the run, else the first member access: what the new method mostly does.
    private static func firstCall(in run: [CodeBlockItemSyntax], file: SwiftRefactoringFile) -> ExprSyntax? {
        for item in run {
            for token in item.tokens(viewMode: .sourceAccurate) {
                let position = token.positionAfterSkippingLeadingTrivia.utf8Offset
                guard let start = file.tree.token(at: AbsolutePosition(utf8Offset: position)) else { continue }
                var node: Syntax? = Syntax(start)
                while let current = node, SwiftRefactoringFile.trimmed(current).upperBound <= SwiftRefactoringFile.trimmed(run.last!).upperBound {
                    if let call = current.as(FunctionCallExprSyntax.self) { return ExprSyntax(call) }
                    if let member = current.as(MemberAccessExprSyntax.self) { return ExprSyntax(member) }
                    node = current.parent
                }
            }
        }
        return nil
    }

    private static func numbered(_ root: String, avoiding used: Set<String>) -> String {
        var candidate = root
        var suffix = 2
        while used.contains(candidate) {
            candidate = "\(root)\(suffix)"
            suffix += 1
        }
        return candidate
    }

    /// Rewrites the selection to a call and adds the new method, or says why it cannot be done.
    public static func edits(in text: String, selection: Range<Int>, name requested: String) -> SwiftRefactoringResult {
        guard let file = SwiftRefactoringFile.load(text) else {
            return .failure(.init("The file has syntax errors; fix them before refactoring."))
        }
        guard SwiftIdentifiers.isValid(requested) else {
            return .failure(.init("'\(requested)' is not a valid name."))
        }
        let trimmed = file.trimmedBytes(selection)
        guard !trimmed.isEmpty else {
            return .failure(.init("Select whole statements or one complete expression."))
        }
        // What the selection is: whole statements or one expression.
        let run = file.statementRun(exactly: selection)
        let expression = run == nil ? file.expression(exactly: trimmed) : nil
        guard run != nil || expression != nil else {
            return .failure(.init("Select whole statements or one complete expression."))
        }
        if let expression, let parent = expression.parent {
            if parent.is(TryExprSyntax.self) {
                return .failure(.init("Select the whole 'try' expression."))
            }
            if parent.is(AwaitExprSyntax.self) {
                return .failure(.init("Select the whole 'await' expression."))
            }
            if parent.is(InOutExprSyntax.self) {
                return .failure(.init("Cannot extract an 'inout' argument."))
            }
            if isAssignmentTarget(expression, parent: parent) {
                return .failure(.init("Cannot extract an assignment target."))
            }
            var blocker: Syntax? = parent
            while let current = blocker {
                if current.is(KeyPathExprSyntax.self) || current.is(MacroExpansionExprSyntax.self) {
                    return .failure(.init("Cannot extract a key path or macro argument."))
                }
                blocker = current.parent
            }
        }
        // Whose function it is in: a function, not a closure and not the file.
        let anchor: Syntax = run?.first.map(Syntax.init) ?? Syntax(expression!)
        var scope: Syntax? = anchor
        var function: FunctionDeclSyntax?
        while let current = scope {
            if current.is(ClosureExprSyntax.self) {
                return .failure(.init("Cannot extract code from inside a closure."))
            }
            if let found = current.as(FunctionDeclSyntax.self) {
                function = found
                break
            }
            scope = current.parent
        }
        guard let function else {
            return .failure(.init("Select code inside a function."))
        }
        // A nested function cannot host the new method: `private` is illegal in a local scope, so
        // selections inside one are refused instead of being lifted to the outer function.
        var holder: Syntax? = Syntax(function).parent
        while let current = holder {
            if current.is(FunctionDeclSyntax.self) {
                return .failure(.init("Cannot extract code from inside a local function."))
            }
            holder = current.parent
        }
        let functionRange = SwiftRefactoringFile.trimmed(Syntax(function))
        let functionIndent = file.indentation(before: functionRange.lowerBound) ?? ""
        // The requested name must be new to the type (or the file) and to the function.
        if let holder = enclosingType(of: Syntax(function)) {
            if memberNames(of: holder).contains(requested) {
                return .failure(.init("'\(requested)' already exists in this type."))
            }
        } else if topLevelNames(in: file).contains(requested) {
            return .failure(.init("'\(requested)' is already declared in this file."))
        }
        if localNames(in: function).contains(requested) {
            return .failure(.init("'\(requested)' is already declared here."))
        }
        let span: Range<Int>
        let body: String
        let discarded: Bool
        /// The run sits in a guard's `else` body without covering all of it: a throwing extraction
        /// is decided once effects are known.
        var throwingGuardElse = false
        /// A lone expression that is the whole body of a function with a declared return type is
        /// the implicit return, not a discarded statement: extracting it keeps the value, and the
        /// call site gains an explicit `return`.
        var implicitReturn: ExprSyntax?
        if let run {
            span = SwiftRefactoringFile.trimmed(run.first!).lowerBound ..< SwiftRefactoringFile.trimmed(run.last!).upperBound
            if let stopped = controlFlowLeaving(run: run, span: span) {
                return .failure(stopped)
            }
            if run.contains(where: {
                if case .stmt(let statement) = $0.item { return statement.is(DeferStmtSyntax.self) }
                return false
            }) {
                return .failure(.init("Cannot extract a 'defer' statement."))
            }
            if run.count == 1, case .expr(let sole) = run.first!.item,
               function.signature.returnClause != nil,
               let list = Syntax(run.first!).parent?.as(CodeBlockItemListSyntax.self), list.count == 1,
               list.parent?.parent?.as(FunctionDeclSyntax.self)?.id == Syntax(function).id {
                // The value the implicit return carries has to be known; otherwise this is a
                // whole-body extraction the call site cannot give a value to.
                if inferredType(of: sole, in: file) != nil {
                    implicitReturn = sole
                } else {
                    return .failure(.init("Cannot extract the whole body of a function that returns a value."))
                }
            }
            if implicitReturn != nil {
                discarded = false
                body = (functionIndent + "    ") + "return " + file.string(span)
            } else {
                discarded = true
                body = (file.indentation(before: span.lowerBound) ?? "") + file.string(span)
            }
            // A guard's `else` body must not fall through: extracting all of it would leave a
            // returning call behind, and a throwing extraction might return where it cannot.
            if let list = Syntax(run.first!).parent?.as(CodeBlockItemListSyntax.self),
               let block = list.parent?.as(CodeBlockSyntax.self),
               let guardStmt = block.parent?.as(GuardStmtSyntax.self),
               guardStmt.body.id == block.id {
                if list.count == run.count, list.first?.id == run.first!.id {
                    return .failure(.init("Cannot extract the whole body of a 'guard'."))
                }
                throwingGuardElse = true
            }
            // A discarded run that is the whole body of a function with a declared return type
            // would leave the call site without a value.
            if discarded, function.signature.returnClause != nil,
               let statements = function.body?.statements,
               statements.count == run.count,
               statements.first?.id == run.first!.id,
               statements.last?.id == run.last!.id {
                return .failure(.init("Cannot extract the whole body of a function that returns a value."))
            }
        } else {
            span = SwiftRefactoringFile.trimmed(expression!)
            // A statement of its own: the value goes nowhere. (A whole-body lone expression
            // never reaches here: it matches as a one-statement run first.)
            var statement = false
            var node: Syntax? = Syntax(expression!)
            while let current = node {
                if let item = current.as(CodeBlockItemSyntax.self) {
                    if case .expr(let discarded) = item.item {
                        statement = discarded.id == expression!.id
                    }
                    break
                }
                node = current.parent
            }
            discarded = statement
            // A fresh `return` line lives at the new method's level, not mid-line where selected.
            let returned = functionIndent + "    "
            body = statement ? returned + file.string(span) : returned + "return " + file.string(span)
        }
        // `$0` never resolves to a binding, so it needs a textual scan: it cannot be a parameter.
        for token in file.tree.tokens(viewMode: .sourceAccurate) {
            let position = token.positionAfterSkippingLeadingTrivia.utf8Offset
            guard span.lowerBound <= position, position < span.upperBound else { continue }
            let dollar: String? = switch token.tokenKind {
            case .identifier(let text), .dollarIdentifier(let text): text
            default: nil
            }
            if let dollar, dollar.hasPrefix("$"), dollar.count > 1, dollar.dropFirst().allSatisfy({ $0.isNumber }) {
                return .failure(.init("Cannot extract code that uses '\(dollar)'."))
            }
        }
        // Assigning to an initialized `let`, to a `let` left behind, to a plain parameter, or
        // taking any of those with `&` never compiles: the extraction would only move the error.
        // A `let` declared without a value inside the selection keeps its deferred initialization.
        for reference in file.references {
            guard span.lowerBound <= reference.bytes.lowerBound, reference.bytes.upperBound <= span.upperBound else { continue }
            guard case .local(let declaration, _) = reference.resolution else { continue }
            guard assigns(name: reference.name, bytes: declaration, in: span, file: file) else { continue }
            guard let declared = classify(declaration: declaration, file: file) else { continue }
            switch declared {
            case .binding(let specifier, _, _, let initializer, _):
                guard specifier == "let" else { continue }
                if initializer != nil || declaration.upperBound <= span.lowerBound
                    || inoutOperand(name: reference.name, bytes: declaration, in: span, file: file) {
                    return .failure(.init("Cannot extract code that assigns to '\(reference.name)', which is not mutable here."))
                }
            case .parameter(let type):
                if !file.string(SwiftRefactoringFile.trimmed(type)).hasPrefix("inout ") {
                    return .failure(.init("Cannot extract code that assigns to '\(reference.name)', which is not mutable here."))
                }
            case .unsupported:
                break
            }
        }
        // What the selection reads: locals declared before it, inside the function.
        let inputs: [Input]
        do {
            inputs = try Self.inputs(in: span, function: function, file: file)
        } catch let failure as SwiftRefactoringFailure {
            return .failure(failure)
        } catch {
            return .failure(.init(error.localizedDescription))
        }
        // What it leaves behind: at most one declaration used after it. A whole-body lone
        // expression is valued like a selected expression.
        let output: Output?
        do {
            output = try Self.output(in: span, expression: implicitReturn ?? expression, discarded: discarded, file: file)
        } catch let failure as SwiftRefactoringFailure {
            return .failure(failure)
        } catch {
            return .failure(.init(error.localizedDescription))
        }
        // Effects the selection carries out: throwing or awaiting calls make the method match.
        let (isThrowing, isAsync) = effects(in: span, file: file)
        if throwingGuardElse, isThrowing {
            return .failure(.init("Cannot extract throwing code from a 'guard' body."))
        }
        // No extracted type may mention the enclosing function's generic parameters.
        let genericParameters: Set<String> = {
            guard let clause = function.genericParameterClause else { return [] }
            return Set(clause.parameters.map { $0.name.text })
        }()
        if !genericParameters.isEmpty {
            var checked = inputs.map(\.type) + internalTypes(in: span, file: file)
            if let output { checked.append(output.type) }
            for parameter in genericParameters {
                for text in checked where mentions(name: parameter, inType: text) {
                    return .failure(.init("Cannot extract code that mentions generic parameter '\(parameter)'."))
                }
            }
        }
        return build(
            name: requested, span: span, body: body, discarded: discarded,
            inputs: inputs, output: output, isThrowing: isThrowing, isAsync: isAsync,
            function: function, file: file, callReturns: implicitReturn != nil
        )
    }

    // MARK: - Assignment targets

    static let assignmentOperators: Set<String> = [
        "=", "+=", "-=", "*=", "/=", "%=", "<<=", ">>=", "&=", "|=", "^=",
    ]

    /// Whether `expression` is written by its parent: an assignment target or an `inout` argument.
    /// `try`, `await`, selectors and key paths are refused earlier.
    static func isAssignmentTarget(_ expression: ExprSyntax, parent: Syntax) -> Bool {
        let trimmed = SwiftRefactoringFile.trimmed(expression)
        if let infixOperator = parent.as(InfixOperatorExprSyntax.self),
           assignmentOperators.contains(infixOperator.operator.trimmedDescription),
           SwiftRefactoringFile.trimmed(infixOperator.leftOperand).upperBound == trimmed.upperBound {
            return true
        }
        if let sequence = parent.as(SequenceExprSyntax.self) {
            let elements = Array(sequence.elements)
            if let index = elements.firstIndex(where: { $0.id == expression.id }), index + 1 < elements.count,
               assignmentOperators.contains(elements[index + 1].trimmedDescription) {
                return true
            }
        }
        return false
    }

    // MARK: - Control flow

    /// A `return`, `break`, `continue` or `fallthrough` in the run whose target lies outside it.
    static func controlFlowLeaving(run: [CodeBlockItemSyntax], span: Range<Int>) -> SwiftRefactoringFailure? {
        func inside(_ node: Syntax) -> Bool {
            let range = SwiftRefactoringFile.trimmed(node)
            return range.lowerBound >= span.lowerBound && range.upperBound <= span.upperBound
        }
        for item in run {
            for token in item.tokens(viewMode: .sourceAccurate) {
                var node: Syntax? = Syntax(token)
                while let current = node, inside(current) {
                    if current.is(ReturnStmtSyntax.self) {
                        // A return nested in a closure or local function stays inside it.
                        var scope: Syntax? = current.parent
                        var leaves = true
                        while let enclosing = scope, inside(enclosing) {
                            if enclosing.is(ClosureExprSyntax.self) || enclosing.is(FunctionDeclSyntax.self)
                                || enclosing.is(AccessorDeclSyntax.self) || enclosing.is(InitializerDeclSyntax.self)
                                || enclosing.is(SubscriptDeclSyntax.self) {
                                leaves = false
                                break
                            }
                            scope = enclosing.parent
                        }
                        if leaves { return .init("Cannot extract a 'return' statement.") }
                        break
                    }
                    if current.is(BreakStmtSyntax.self) || current.is(ContinueStmtSyntax.self) {
                        let label: String? = {
                            if let statement = current.as(BreakStmtSyntax.self) { return statement.label?.text }
                            if let statement = current.as(ContinueStmtSyntax.self) { return statement.label?.text }
                            return nil
                        }()
                        var scope: Syntax? = current.parent
                        var stays = false
                        while let enclosing = scope, inside(enclosing) {
                            if let label, let labeled = enclosing.as(LabeledStmtSyntax.self),
                               labeled.label.text == label {
                                stays = true
                                break
                            }
                            if label == nil, enclosing.is(ForStmtSyntax.self) || enclosing.is(WhileStmtSyntax.self)
                                || enclosing.is(RepeatStmtSyntax.self) || enclosing.is(SwitchExprSyntax.self) {
                                stays = true
                                break
                            }
                            if enclosing.is(ClosureExprSyntax.self) || enclosing.is(FunctionDeclSyntax.self) {
                                break
                            }
                            scope = enclosing.parent
                        }
                        if !stays { return .init("Cannot extract a 'break' or 'continue' statement.") }
                        break
                    }
                    if current.is(FallThroughStmtSyntax.self) {
                        var scope: Syntax? = current.parent
                        var stays = false
                        while let enclosing = scope, inside(enclosing) {
                            if enclosing.is(SwitchExprSyntax.self) { stays = true; break }
                            scope = enclosing.parent
                        }
                        if !stays { return .init("Cannot extract a 'fallthrough' statement.") }
                        break
                    }
                    node = current.parent
                }
            }
        }
        return nil
    }

    // MARK: - Enclosing names

    /// The type the new method joins, if the function is a member of one.
    static func enclosingType(of node: Syntax) -> Syntax? {
        var current: Syntax? = node.parent
        while let candidate = current {
            if candidate.is(StructDeclSyntax.self) || candidate.is(ClassDeclSyntax.self)
                || candidate.is(EnumDeclSyntax.self) || candidate.is(ActorDeclSyntax.self)
                || candidate.is(ExtensionDeclSyntax.self) || candidate.is(ProtocolDeclSyntax.self) {
                return candidate
            }
            current = candidate.parent
        }
        return nil
    }

    /// The names a new member would collide with: functions, bindings, types and cases.
    static func memberNames(of typeDecl: Syntax) -> Set<String> {
        var names = Set<String>()
        var block: MemberBlockItemListSyntax?
        if let decl = typeDecl.as(StructDeclSyntax.self) { block = decl.memberBlock.members }
        else if let decl = typeDecl.as(ClassDeclSyntax.self) { block = decl.memberBlock.members }
        else if let decl = typeDecl.as(EnumDeclSyntax.self) { block = decl.memberBlock.members }
        else if let decl = typeDecl.as(ActorDeclSyntax.self) { block = decl.memberBlock.members }
        else if let decl = typeDecl.as(ExtensionDeclSyntax.self) { block = decl.memberBlock.members }
        else if let decl = typeDecl.as(ProtocolDeclSyntax.self) { block = decl.memberBlock.members }
        for item in block ?? [] {
            let decl = item.decl
            if let function = decl.as(FunctionDeclSyntax.self) { names.insert(function.name.text) }
            else if let variable = decl.as(VariableDeclSyntax.self) {
                names.formUnion(patternNames(in: variable))
            } else if let type = decl.as(StructDeclSyntax.self) { names.insert(type.name.text) }
            else if let type = decl.as(ClassDeclSyntax.self) { names.insert(type.name.text) }
            else if let type = decl.as(EnumDeclSyntax.self) { names.insert(type.name.text) }
            else if let type = decl.as(ActorDeclSyntax.self) { names.insert(type.name.text) }
            else if let type = decl.as(ProtocolDeclSyntax.self) { names.insert(type.name.text) }
            else if let type = decl.as(TypeAliasDeclSyntax.self) { names.insert(type.name.text) }
            else if let cases = decl.as(EnumCaseDeclSyntax.self) {
                for element in cases.elements { names.insert(element.name.text) }
            }
        }
        return names
    }

    /// Every identifier a pattern binds.
    static func patternNames(in variable: VariableDeclSyntax) -> Set<String> {
        var names = Set<String>()
        for binding in variable.bindings {
            for token in binding.pattern.tokens(viewMode: .sourceAccurate) {
                if case .identifier(let text) = token.tokenKind { names.insert(text) }
            }
        }
        return names
    }

    /// The top-level function, variable and type names of the file.
    static func topLevelNames(in file: SwiftRefactoringFile) -> Set<String> {
        var names = Set<String>()
        for item in file.tree.statements {
            guard case .decl(let decl) = item.item else { continue }
            if let function = decl.as(FunctionDeclSyntax.self) { names.insert(function.name.text) }
            else if let variable = decl.as(VariableDeclSyntax.self) { names.formUnion(patternNames(in: variable)) }
            else if let type = decl.as(StructDeclSyntax.self) { names.insert(type.name.text) }
            else if let type = decl.as(ClassDeclSyntax.self) { names.insert(type.name.text) }
            else if let type = decl.as(EnumDeclSyntax.self) { names.insert(type.name.text) }
            else if let type = decl.as(ActorDeclSyntax.self) { names.insert(type.name.text) }
            else if let type = decl.as(ProtocolDeclSyntax.self) { names.insert(type.name.text) }
            else if let type = decl.as(TypeAliasDeclSyntax.self) { names.insert(type.name.text) }
        }
        return names
    }

    // MARK: - Inputs

    struct Input {
        let name: String
        let type: String
        let isInout: Bool
    }

    /// A local declaration the selection may read: a binding with its specifier, annotation and
    /// initializer, a parameter with its type, or something that cannot go through a parameter.
    enum LocalDeclaration {
        case binding(specifier: String, modifiersEmpty: Bool, annotation: TypeSyntax?, initializer: ExprSyntax?, single: Bool)
        case parameter(type: TypeSyntax)
        case unsupported(kind: String)
    }

    /// The locals the selection reads from before it, in first-use order.
    static func inputs(in span: Range<Int>, function: FunctionDeclSyntax, file: SwiftRefactoringFile) throws -> [Input] {
        let functionRange = SwiftRefactoringFile.trimmed(Syntax(function))
        var seen = Set<Range<Int>>()
        var inputs: [Input] = []
        for reference in file.references {
            guard span.lowerBound <= reference.bytes.lowerBound, reference.bytes.upperBound <= span.upperBound else { continue }
            switch reference.resolution {
            case .implicit:
                throw SwiftRefactoringFailure("Cannot extract code that uses '\(reference.name)'.")
            case .outer:
                if reference.name.first == "$", reference.name.dropFirst().allSatisfy({ $0.isNumber }) {
                    throw SwiftRefactoringFailure("Cannot extract code that uses '\(reference.name)'.")
                }
            case .local(let declaration, _):
                guard declaration.lowerBound < span.lowerBound else { continue }
                guard functionRange.lowerBound <= declaration.lowerBound, declaration.upperBound <= functionRange.upperBound else {
                    throw SwiftRefactoringFailure("Cannot extract code that uses '\(reference.name)', declared outside the function.")
                }
                guard !seen.contains(declaration) else { continue }
                seen.insert(declaration)
                guard let declared = classify(declaration: declaration, file: file) else {
                    throw SwiftRefactoringFailure("Cannot tell the type of '\(reference.name)'; add an explicit type or use SourceKit's Extract Method.")
                }
                switch declared {
                case .unsupported(let kind):
                    throw SwiftRefactoringFailure("Cannot extract code that uses '\(reference.name)', \(kind).")
                case .parameter(let type):
                    let text = file.string(SwiftRefactoringFile.trimmed(type))
                    let (stripped, inoutParam) = strippingInout(text)
                    inputs.append(Input(name: reference.name, type: stripped, isInout: inoutParam && writes(name: reference.name, bytes: declaration, in: span, file: file)))
                case .binding(_, _, let annotation, let initializer, _):
                    guard let type = annotation.map({ file.string(SwiftRefactoringFile.trimmed($0)) })
                        ?? initializer.flatMap({ inferredType(of: $0, in: file) }) else {
                        throw SwiftRefactoringFailure("Cannot tell the type of '\(reference.name)'; add an explicit type or use SourceKit's Extract Method.")
                    }
                    inputs.append(Input(name: reference.name, type: type, isInout: false))
                }
            }
        }
        // Inout needs the writes: a var the selection assigns, bases a member on, or takes with &.
        return inputs.map { input in
            guard !input.isInout, isMutableBinding(named: input.name, in: span, file: file),
                  writes(name: input.name, bytes: nil, in: span, file: file) else { return input }
            return Input(name: input.name, type: input.type, isInout: true)
        }
    }

    /// What the name's declaration is, found from the declaring name's bytes.
    static func classify(declaration: Range<Int>, file: SwiftRefactoringFile) -> LocalDeclaration? {
        guard let token = file.tree.token(at: AbsolutePosition(utf8Offset: declaration.lowerBound)) else { return nil }
        var node: Syntax? = Syntax(token)
        while let current = node {
            if let binding = current.as(PatternBindingSyntax.self) {
                let specifier: String
                let modifiersEmpty: Bool
                let single: Bool
                // The variable declaration sits above the binding list, not on the binding.
                var holder: Syntax? = Syntax(binding)
                while let up = holder?.parent, up.is(PatternBindingListSyntax.self) { holder = up }
                if let variable = holder?.parent?.as(VariableDeclSyntax.self) {
                    specifier = variable.bindingSpecifier.text
                    modifiersEmpty = variable.modifiers.isEmpty
                    single = variable.bindings.count == 1
                } else {
                    specifier = "let"
                    modifiersEmpty = true
                    single = true
                }
                return .binding(
                    specifier: specifier, modifiersEmpty: modifiersEmpty,
                    annotation: binding.typeAnnotation?.type, initializer: binding.initializer?.value, single: single
                )
            }
            if let condition = current.as(OptionalBindingConditionSyntax.self) {
                return .binding(
                    specifier: condition.bindingSpecifier.text, modifiersEmpty: true,
                    annotation: condition.typeAnnotation?.type, initializer: condition.initializer?.value, single: true
                )
            }
            if let parameter = current.as(FunctionParameterSyntax.self) {
                return .parameter(type: parameter.type)
            }
            if let closureParameter = current.as(ClosureParameterSyntax.self) {
                guard let type = closureParameter.type else { return nil }
                return .parameter(type: type)
            }
            if current.is(FunctionDeclSyntax.self) { return .unsupported(kind: "a local function") }
            if current.is(StructDeclSyntax.self) || current.is(ClassDeclSyntax.self) || current.is(EnumDeclSyntax.self)
                || current.is(ActorDeclSyntax.self) || current.is(ProtocolDeclSyntax.self) || current.is(TypeAliasDeclSyntax.self) {
                return .unsupported(kind: "a local type")
            }
            node = current.parent
        }
        return nil
    }

    /// Splits a leading `inout`: parameters spell it in the type, and it decides mutability.
    static func strippingInout(_ text: String) -> (String, Bool) {
        if text.hasPrefix("inout ") { return (String(text.dropFirst("inout ".count)), true) }
        return (text, false)
    }

    /// The shared literal types plus the numeric and collection literals a parameter or return
    /// type needs: `-5` is `Int`, `[1, 2]` is `[Int]`. The shared `type(of:)` stays untouched so
    /// Introduce Variable keeps its committed behavior.
    static func inferredType(of expression: ExprSyntax, in file: SwiftRefactoringFile) -> String? {
        if let known = SwiftAddExplicitType.type(of: expression) {
            // `Set(symbols)` constructs a generic type whose arguments only the type checker knows;
            // writing the bare name would not compile, so this is untypable, not `Set`.
            if genericOnlyTypes.contains(known),
               let call = expression.as(FunctionCallExprSyntax.self),
               call.calledExpression.as(DeclReferenceExprSyntax.self) != nil {
                return nil
            }
            // A bare capitalized call reads as a type construction, but C functions spell that
            // way too (`CTLineCreateWithAttributedString(...)` is not a type). Trust it only for
            // the standard value types or a name the file itself uses as a type.
            if let call = expression.as(FunctionCallExprSyntax.self),
               let callee = call.calledExpression.as(DeclReferenceExprSyntax.self),
               callee.argumentNames == nil,
               !plainValueTypes.contains(callee.baseName.text),
               !mentionedAsType(named: callee.baseName.text, in: file) {
                return nil
            }
            return known
        }
        return literalType(of: expression, in: file)
    }

    /// Standard library types that are generic over arguments no syntax can name when constructed
    /// without an explicit specialization (`Set<Int>(...)` stays known through the specialization).
    private static let genericOnlyTypes: Set<String> = ["Set", "Array", "Dictionary", "Optional"]

    /// Non-generic standard library value types: `String(x)` is always the type `String`.
    private static let plainValueTypes: Set<String> = [
        "String", "Bool", "Character", "Double", "Float",
        "Int", "Int8", "Int16", "Int32", "Int64",
        "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
    ]

    /// Whether the file uses the name where only a type can stand (an annotation, a return clause,
    /// a cast, a generic argument) or declares it as a nominal type: what tells `Foo(...)` the
    /// type construction apart from a C function that happens to start with a capital.
    static func mentionedAsType(named name: String, in file: SwiftRefactoringFile) -> Bool {
        for token in file.tree.tokens(viewMode: .sourceAccurate) {
            guard case .identifier(let text) = token.tokenKind, text == name else { continue }
            var node: Syntax? = Syntax(token)
            while let current = node {
                if current.is(TypeSyntax.self) { return true }
                if isNominalName(token, of: current) { return true }
                // Anything else gives the token its role first: a call callee, a member, or a
                // binding inside one of these is not a type mention, no matter what sits above.
                if current.is(ExprSyntax.self) || current.is(StmtSyntax.self)
                    || current.is(PatternSyntax.self) {
                    break
                }
                node = current.parent
            }
        }
        return false
    }

    /// Whether the token is the introduced name of the nominal declaration itself (`struct Foo`).
    private static func isNominalName(_ token: TokenSyntax, of node: Syntax) -> Bool {
        let position = token.positionAfterSkippingLeadingTrivia
        if let decl = node.as(StructDeclSyntax.self) { return decl.name.positionAfterSkippingLeadingTrivia == position }
        if let decl = node.as(ClassDeclSyntax.self) { return decl.name.positionAfterSkippingLeadingTrivia == position }
        if let decl = node.as(EnumDeclSyntax.self) { return decl.name.positionAfterSkippingLeadingTrivia == position }
        if let decl = node.as(ActorDeclSyntax.self) { return decl.name.positionAfterSkippingLeadingTrivia == position }
        if let decl = node.as(ProtocolDeclSyntax.self) { return decl.name.positionAfterSkippingLeadingTrivia == position }
        if let decl = node.as(TypeAliasDeclSyntax.self) { return decl.name.positionAfterSkippingLeadingTrivia == position }
        return false
    }

    static func literalType(of expression: ExprSyntax, in file: SwiftRefactoringFile) -> String? {
        if expression.is(IntegerLiteralExprSyntax.self) { return "Int" }
        if expression.is(FloatLiteralExprSyntax.self) { return "Double" }
        if let prefix = expression.as(PrefixOperatorExprSyntax.self),
           ["-", "+"].contains(prefix.operator.trimmedDescription) {
            return inferredType(of: prefix.expression, in: file)
        }
        if let array = expression.as(ArrayExprSyntax.self) {
            var element: String?
            for item in array.elements {
                guard let type = inferredType(of: item.expression, in: file), element.map({ $0 == type }) ?? true else { return nil }
                element = type
            }
            guard let element else { return nil }
            return "[\(element)]"
        }
        if let dictionary = expression.as(DictionaryExprSyntax.self),
           case .elements(let elements) = dictionary.content {
            var key: String?
            var value: String?
            for element in elements {
                guard let keyType = inferredType(of: element.key, in: file), key.map({ $0 == keyType }) ?? true,
                      let valueType = inferredType(of: element.value, in: file), value.map({ $0 == valueType }) ?? true else { return nil }
                key = keyType
                value = valueType
            }
            guard let key, let value else { return nil }
            return "[\(key): \(value)]"
        }
        return nil
    }

    /// Whether the name binds with `var` (or is an `inout` parameter): only those become `inout`.
    static func isMutableBinding(named name: String, in span: Range<Int>, file: SwiftRefactoringFile) -> Bool {
        for reference in file.references {
            guard span.lowerBound <= reference.bytes.lowerBound, reference.bytes.upperBound <= span.upperBound else { continue }
            guard case .local(let declaration, _) = reference.resolution, reference.name == name else { continue }
            guard declaration.lowerBound < span.lowerBound else { continue }
            guard let declared = classify(declaration: declaration, file: file) else { continue }
            switch declared {
            case .binding(let specifier, _, _, _, _):
                return specifier == "var"
            case .parameter(let type):
                // A plain parameter cannot be written (assigning to it does not compile); only an
                // `inout` one can come back changed.
                return file.string(SwiftRefactoringFile.trimmed(type)).hasPrefix("inout ")
            case .unsupported:
                return false
            }
        }
        return false
    }

    /// Whether the selection writes the name, bases a member or subscript on it, or takes it with
    /// `&`. When `bytes` is given, only writes through that declaration's references count.
    static func writes(name: String, bytes: Range<Int>?, in span: Range<Int>, file: SwiftRefactoringFile) -> Bool {
        for reference in file.references {
            guard reference.name == name else { continue }
            guard span.lowerBound <= reference.bytes.lowerBound, reference.bytes.upperBound <= span.upperBound else { continue }
            if let bytes {
                guard case .local(let declaration, _) = reference.resolution, declaration == bytes else { continue }
            }
            guard let token = file.tree.token(at: AbsolutePosition(utf8Offset: reference.bytes.lowerBound)) else { continue }
            var node: Syntax? = Syntax(token)
            while let current = node {
                let range = SwiftRefactoringFile.trimmed(current)
                guard range.lowerBound >= span.lowerBound, range.upperBound <= span.upperBound else { break }
                if current.is(InOutExprSyntax.self) { return true }
                if let infixOperator = current.as(InfixOperatorExprSyntax.self),
                   assignmentOperators.contains(infixOperator.operator.trimmedDescription),
                   SwiftRefactoringFile.trimmed(infixOperator.leftOperand).upperBound == reference.bytes.upperBound {
                    return true
                }
                if let access = current.as(MemberAccessExprSyntax.self), let base = access.base,
                   SwiftRefactoringFile.trimmed(base).upperBound == reference.bytes.upperBound {
                    return true
                }
                if let subscriptCall = current.as(SubscriptCallExprSyntax.self),
                   SwiftRefactoringFile.trimmed(subscriptCall.calledExpression).upperBound == reference.bytes.upperBound {
                    return true
                }
                if let infixOperator = current.as(InfixOperatorExprSyntax.self),
                   assignmentOperators.contains(infixOperator.operator.trimmedDescription),
                   SwiftRefactoringFile.trimmed(infixOperator.leftOperand).upperBound == reference.bytes.upperBound {
                    return true
                }
                if let sequence = current.as(SequenceExprSyntax.self) {
                    let elements = Array(sequence.elements)
                    if let index = elements.firstIndex(where: { SwiftRefactoringFile.trimmed($0).upperBound == reference.bytes.upperBound }),
                       index + 1 < elements.count,
                       assignmentOperators.contains(elements[index + 1].trimmedDescription) {
                        return true
                    }
                }
                node = current.parent
            }
        }
        return false
    }

    /// Whether the selection assigns the name or takes it with `&`, through the given declaration:
    /// the direct writes, without the member and subscript bases `writes` also counts (reading a
    /// member of a `let` is fine; assigning to one is not).
    static func assigns(name: String, bytes: Range<Int>, in span: Range<Int>, file: SwiftRefactoringFile) -> Bool {
        for reference in file.references {
            guard reference.name == name else { continue }
            guard span.lowerBound <= reference.bytes.lowerBound, reference.bytes.upperBound <= span.upperBound else { continue }
            guard case .local(let declaration, _) = reference.resolution, declaration == bytes else { continue }
            guard let token = file.tree.token(at: AbsolutePosition(utf8Offset: reference.bytes.lowerBound)) else { continue }
            var node: Syntax? = Syntax(token)
            while let current = node {
                let range = SwiftRefactoringFile.trimmed(current)
                guard range.lowerBound >= span.lowerBound, range.upperBound <= span.upperBound else { break }
                if current.is(InOutExprSyntax.self) { return true }
                if let infixOperator = current.as(InfixOperatorExprSyntax.self),
                   assignmentOperators.contains(infixOperator.operator.trimmedDescription),
                   SwiftRefactoringFile.trimmed(infixOperator.leftOperand).upperBound == reference.bytes.upperBound {
                    return true
                }
                if let sequence = current.as(SequenceExprSyntax.self) {
                    let elements = Array(sequence.elements)
                    if let index = elements.firstIndex(where: { SwiftRefactoringFile.trimmed($0).upperBound == reference.bytes.upperBound }),
                       index + 1 < elements.count,
                       assignmentOperators.contains(elements[index + 1].trimmedDescription) {
                        return true
                    }
                }
                node = current.parent
            }
        }
        return false
    }

    /// Whether the selection takes the name with `&`, through the given declaration.
    static func inoutOperand(name: String, bytes: Range<Int>, in span: Range<Int>, file: SwiftRefactoringFile) -> Bool {
        for reference in file.references {
            guard reference.name == name else { continue }
            guard span.lowerBound <= reference.bytes.lowerBound, reference.bytes.upperBound <= span.upperBound else { continue }
            guard case .local(let declaration, _) = reference.resolution, declaration == bytes else { continue }
            guard let token = file.tree.token(at: AbsolutePosition(utf8Offset: reference.bytes.lowerBound)) else { continue }
            var node: Syntax? = Syntax(token)
            while let current = node {
                let range = SwiftRefactoringFile.trimmed(current)
                guard range.lowerBound >= span.lowerBound, range.upperBound <= span.upperBound else { break }
                if current.is(InOutExprSyntax.self) { return true }
                node = current.parent
            }
        }
        return false
    }

    /// The bindings and parameters declared in the function: a method name must not shadow them at
    /// the call site.
    static func localNames(in function: FunctionDeclSyntax) -> Set<String> {
        var names = Set<String>()
        for parameter in function.signature.parameterClause.parameters {
            names.insert(parameter.secondName?.text ?? parameter.firstName.text)
        }
        let scope: Syntax = function.body.map(Syntax.init) ?? Syntax(function)
        for token in scope.tokens(viewMode: .sourceAccurate) {
            if case .identifier(let text) = token.tokenKind {
                // Only binding positions: the identifier of a pattern or parameter.
                var node: Syntax? = Syntax(token)
                while let current = node {
                    if current.is(IdentifierPatternSyntax.self) || current.is(FunctionParameterSyntax.self)
                        || current.is(OptionalBindingConditionSyntax.self) {
                        names.insert(text)
                        break
                    }
                    if current.id == Syntax(function).id { break }
                    node = current.parent
                }
            }
        }
        return names
    }

    // MARK: - Outputs

    struct Output {
        let name: String
        let specifier: String
        let type: String
    }

    /// At most one declaration inside the selection that the rest of the function still uses. A
    /// valued expression is the output with the expression's own type.
    static func output(in span: Range<Int>, expression: ExprSyntax?, discarded: Bool, file: SwiftRefactoringFile) throws -> Output? {
        if let expression, !discarded {
            guard let type = inferredType(of: expression, in: file) else {
                throw SwiftRefactoringFailure("Cannot tell the type of the extracted expression; add an explicit type or use SourceKit's Extract Method.")
            }
            return Output(name: "", specifier: "", type: type)
        }
        var found: (declaration: Range<Int>, name: String)?
        for reference in file.references {
            guard reference.bytes.lowerBound >= span.upperBound else { continue }
            guard case .local(let declaration, _) = reference.resolution else { continue }
            guard span.lowerBound <= declaration.lowerBound, declaration.upperBound <= span.upperBound else { continue }
            if let found, found.declaration != declaration {
                throw SwiftRefactoringFailure("The selection leaves more than one value behind.")
            }
            found = (declaration, reference.name)
        }
        guard let found else { return nil }
        guard let declared = classify(declaration: found.declaration, file: file) else {
            throw SwiftRefactoringFailure("Cannot tell the type of '\(found.name)'; add an explicit type or use SourceKit's Extract Method.")
        }
        switch declared {
        case .unsupported(let kind):
            throw SwiftRefactoringFailure("Cannot extract code that declares '\(found.name)', \(kind), used after the selection.")
        case .parameter:
            throw SwiftRefactoringFailure("Cannot extract code that declares '\(found.name)', used after the selection.")
        case .binding(let specifier, let modifiersEmpty, let annotation, let initializer, let single):
            guard single, modifiersEmpty else {
                throw SwiftRefactoringFailure("Cannot return '\(found.name)' from the selection.")
            }
            if initializer == nil,
               !writes(name: found.name, bytes: found.declaration, in: span, file: file) {
                throw SwiftRefactoringFailure("Cannot return '\(found.name)' from the selection: it is declared without a value here.")
            }
            guard let type = annotation.map({ file.string(SwiftRefactoringFile.trimmed($0)) })
                ?? initializer.flatMap({ inferredType(of: $0, in: file) }) else {
                throw SwiftRefactoringFailure("Cannot tell the type of '\(found.name)'; add an explicit type or use SourceKit's Extract Method.")
            }
            return Output(name: found.name, specifier: specifier == "var" ? "var" : "let", type: type)
        }
    }

    /// Every type written inside the selection, for the generic-parameter check.
    static func internalTypes(in span: Range<Int>, file: SwiftRefactoringFile) -> [String] {
        var types: [String] = []
        for token in file.tree.tokens(viewMode: .sourceAccurate) {
            let position = token.positionAfterSkippingLeadingTrivia.utf8Offset
            guard span.lowerBound <= position, position < span.upperBound else { continue }
            var node: Syntax? = Syntax(token)
            while let current = node {
                let range = SwiftRefactoringFile.trimmed(current)
                guard range.lowerBound >= span.lowerBound, range.upperBound <= span.upperBound else { break }
                if current.is(TypeSyntax.self) {
                    types.append(file.string(range))
                    break
                }
                node = current.parent
            }
        }
        return types
    }

    /// Whether `name` occurs in the type text as its own identifier.
    static func mentions(name: String, inType text: String) -> Bool {
        var scalars = text.unicodeScalars.makeIterator()
        var word = ""
        func flush() -> Bool {
            defer { word = "" }
            return word == name
        }
        var hit = false
        while let scalar = scalars.next() {
            if scalar == "_" || scalar.properties.isAlphabetic || ("0" ... "9").contains(scalar) {
                word.unicodeScalars.append(scalar)
            } else if flush() {
                hit = true
            }
        }
        return hit || flush()
    }

    // MARK: - Effects

    /// Whether a bare `try` or `await` inside the selection escapes with it: nested closures keep
    /// their own. As `effects` does, `try?` and `try!` stay where they are.
    static func effects(in span: Range<Int>, file: SwiftRefactoringFile) -> (isThrowing: Bool, isAsync: Bool) {
        func inside(_ node: Syntax) -> Bool {
            let range = SwiftRefactoringFile.trimmed(node)
            return range.lowerBound >= span.lowerBound && range.upperBound <= span.upperBound
        }
        // Whether the effect belongs to the extracted code itself rather than a nested closure,
        // accessor, or local declaration, which keeps its own.
        func escapes(_ node: Syntax) -> Bool {
            var scope: Syntax? = node.parent
            while let enclosing = scope, inside(enclosing) {
                if enclosing.is(ClosureExprSyntax.self) || enclosing.is(FunctionDeclSyntax.self)
                    || enclosing.is(AccessorDeclSyntax.self) || enclosing.is(InitializerDeclSyntax.self)
                    || enclosing.is(SubscriptDeclSyntax.self) {
                    return false
                }
                scope = enclosing.parent
            }
            return true
        }
        var isThrowing = false
        var isAsync = false
        for token in file.tree.tokens(viewMode: .sourceAccurate) {
            let position = token.positionAfterSkippingLeadingTrivia.utf8Offset
            guard span.lowerBound <= position, position < span.upperBound else { continue }
            var node: Syntax? = Syntax(token)
            while let current = node, inside(current) {
                if !isThrowing, let attempt = current.as(TryExprSyntax.self),
                   attempt.questionOrExclamationMark == nil, escapes(current) {
                    isThrowing = true
                    break
                }
                if !isThrowing, current.is(ThrowStmtSyntax.self), escapes(current) {
                    isThrowing = true
                    break
                }
                if !isAsync, current.is(AwaitExprSyntax.self), escapes(current) {
                    isAsync = true
                    break
                }
                node = current.parent
            }
        }
        return (isThrowing, isAsync)
    }

    // MARK: - Build

    /// The call that replaces the selection and the new method after the enclosing function.
    static func build(
        name: String, span: Range<Int>, body: String, discarded: Bool,
        inputs: [Input], output: Output?, isThrowing: Bool, isAsync: Bool,
        function: FunctionDeclSyntax, file: SwiftRefactoringFile, callReturns: Bool = false
    ) -> SwiftRefactoringResult {
        let parameters = inputs.map { input in
            "_ \(input.name): \(input.isInout ? "inout " : "")\(input.type)"
        }.joined(separator: ", ")
        let arguments = inputs.map { input in input.isInout ? "&\(input.name)" : input.name }.joined(separator: ", ")
        var call = "\(name)(\(arguments))"
        if isThrowing { call = "try " + call }
        if isAsync { call = "await " + call }
        if callReturns { call = "return " + call }
        if let output, !output.name.isEmpty {
            call = "\(output.specifier) \(output.name) = " + call
        }
        let functionIndent = file.indentation(before: SwiftRefactoringFile.trimmed(Syntax(function)).lowerBound) ?? ""
        var attributes = ""
        for attribute in function.attributes {
            guard let simple = attribute.as(AttributeSyntax.self),
                  simple.arguments == nil, simple.attributeName.as(IdentifierTypeSyntax.self) != nil,
                  let first = simple.attributeName.trimmedDescription.first, first.isUppercase else { continue }
            attributes += "@\(simple.attributeName.trimmedDescription) "
        }
        var modifiers = ""
        if function.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class) }) {
            modifiers += "static "
        }
        if function.modifiers.contains(where: { $0.name.tokenKind == .keyword(.mutating) }) {
            modifiers += "mutating "
        }
        var signature = "\(attributes)private \(modifiers)func \(name)(\(parameters))"
        if isAsync { signature += " async" }
        if isThrowing { signature += " throws" }
        if let output, !discarded || !output.name.isEmpty {
            signature += " -> \(output.type)"
        }
        var methodBody = body
        if let output, !output.name.isEmpty {
            methodBody += "\n" + (file.indentation(before: span.lowerBound) ?? "") + "return " + output.name
        }
        let method = "\n" + functionIndent + signature + " {\n" + methodBody + "\n" + functionIndent + "}"
        let end = SwiftRefactoringFile.trimmed(Syntax(function)).upperBound
        return .success([
            SwiftTextEdit(bytes: span, replacement: call),
            SwiftTextEdit(bytes: end ..< end, replacement: method),
        ])
    }

}
