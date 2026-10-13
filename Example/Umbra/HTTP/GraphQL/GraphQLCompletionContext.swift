import Foundation

/// What may be typed at the caret in a GraphQL document, read from the text before it and the
/// schema. The text can be half typed (unclosed braces, a field name cut off), so the analysis is a
/// single pass over the lexer's tokens with a stack of what is open, not a parse.
enum GraphQLCompletionSite: Equatable, Sendable {
    enum ArgumentOwner: Equatable, Sendable {
        case field(parentType: String, name: String)
        case directive(name: String)
    }

    /// Top level: `query`, `mutation`, `subscription`, `fragment`.
    case operationKeyword
    /// Inside `{ }` of `typeName`: its fields, `__typename`, `...`.
    case selection(typeName: String, variables: [String])
    /// After `...`: `on`, or a fragment name.
    case spread(parentType: String)
    /// Inside `( )` of a field or directive, between arguments.
    case argumentName(owner: ArgumentOwner, used: Set<String>)
    /// After `name:` in arguments or an input object; `typeName` is the expected input type.
    case value(typeName: String?, variables: [String])
    /// Inside `{ }` of an input object value.
    case objectField(typeName: String, used: Set<String>)
    /// After `on`. `parent` is the enclosing selection's type for an inline fragment, nil for a
    /// named fragment definition.
    case typeCondition(parent: String?)
    /// After `$name:` in the variable definitions.
    case variableType
    /// After `@`.
    case directive
}

enum GraphQLCompletionContext {
    /// `text` is the document from its start to the caret. A name touching the caret is the prefix
    /// being typed and is not part of the analysis. Nil: nothing to offer (a string, a comment, the
    /// variables JSON after the operation, an unknown type).
    static func site(in text: String, schema: GraphQLSchema) -> GraphQLCompletionSite? {
        let output = GraphQLLexer.lex(text)
        if output.endsInComment {
            return nil
        }
        var tokens = output.tokens
        let length = (text as NSString).length
        if let last = tokens.last {
            if last.isUnterminated {
                return nil
            }
            if (last.kind == .string || last.kind == .blockString), last.range.upperBound >= length {
                // A closed string that ends at the caret: nothing to complete after it either.
                return nil
            }
            if last.kind == .name, last.range.upperBound == length {
                tokens.removeLast()
            }
        }
        var analysis = Analysis(schema: schema, tokens: tokens)
        return analysis.run()
    }

    private struct Frame {
        enum Kind {
            case selection
            case arguments
            case objectValue
            case list
            case variableDefinitions
        }

        var kind: Kind
        /// Selection: the type being selected on. Object value: the input type. List: its element type.
        var typeName: String?
        /// Arguments: whose.
        var owner: GraphQLCompletionSite.ArgumentOwner?
        /// Arguments and object value: names given so far, and the one awaiting its value.
        var used: Set<String> = []
        var currentName: String?
        var currentType: String?
        var valueGiven = false
        /// Selection: the field or fragment whose `(` or `{` may come next.
        var pendingField: String?
        var pendingFieldType: String?
        var pendingCondition: String?
        var pendingDirective: String?
        var afterSpread = false
        /// Variable definitions: past the `=` of a default value.
        var inDefault = false
    }

    private struct Analysis {
        let schema: GraphQLSchema
        let tokens: [GraphQLToken]
        var stack: [Frame] = []
        var variables: [String] = []

        // Document level.
        var operation: String?
        var isFragment = false
        var fragmentType: String?
        var operationFinished = false
        var isInVariablesJSON = false

        init(schema: GraphQLSchema, tokens: [GraphQLToken]) {
            self.schema = schema
            self.tokens = tokens
        }

        mutating func run() -> GraphQLCompletionSite? {
            var index = 0
            while index < tokens.count {
                let token = tokens[index]
                let next = index + 1 < tokens.count ? tokens[index + 1] : nil
                if isInVariablesJSON {
                    return nil
                }
                if stack.isEmpty {
                    if consumeTopLevel(token, next: next, index: &index) { continue }
                } else {
                    consume(token, next: next, index: &index)
                }
                index += 1
            }
            return currentSite()
        }

        // MARK: Tokens

        /// Returns true when it moved `index` itself.
        mutating func consumeTopLevel(_ token: GraphQLToken, next: GraphQLToken?, index: inout Int) -> Bool {
            switch token.kind {
            case .name:
                switch token.text {
                case "query", "mutation", "subscription":
                    operation = token.text
                    isFragment = false
                    operationFinished = false
                case "fragment":
                    isFragment = true
                    operation = nil
                    operationFinished = false
                case "on" where isFragment:
                    if let next, next.kind == .name {
                        fragmentType = next.text
                        index += 1
                    }
                default:
                    break
                }
            case .punctuator:
                switch token.text {
                case "(":
                    stack.append(Frame(kind: .variableDefinitions))
                case "{":
                    if operationFinished || next?.kind == .string {
                        isInVariablesJSON = true
                        return false
                    }
                    let typeName = isFragment ? fragmentType : schema.rootTypeName(for: operation ?? "query")
                    stack.append(Frame(kind: .selection, typeName: typeName))
                case "@":
                    if let next, next.kind == .name {
                        index += 1
                    }
                default:
                    break
                }
            default:
                break
            }
            return false
        }

        mutating func consume(_ token: GraphQLToken, next: GraphQLToken?, index: inout Int) {
            let top = stack.count - 1
            switch stack[top].kind {
            case .selection:
                consumeInSelection(token, next: next, index: &index)
            case .arguments, .objectValue:
                consumeInValues(token, next: next, index: &index)
            case .list:
                consumeInList(token, index: &index)
            case .variableDefinitions:
                consumeInVariableDefinitions(token, next: next, index: &index)
            }
        }

        mutating func consumeInSelection(_ token: GraphQLToken, next: GraphQLToken?, index: inout Int) {
            let top = stack.count - 1
            switch token.kind {
            case .spread:
                stack[top].afterSpread = true
                stack[top].pendingField = nil
                stack[top].pendingFieldType = nil
                stack[top].pendingCondition = nil
            case .name:
                if let next, next.isPunctuator(":") {
                    // An alias: the field name comes after the colon.
                    index += 1
                    return
                }
                if token.text == "on", stack[top].afterSpread, stack[top].pendingCondition == nil {
                    // `... on` with nothing after it is the caret waiting for the type.
                    if let next, next.kind == .name {
                        stack[top].pendingCondition = next.text
                        stack[top].afterSpread = false
                        index += 1
                    }
                    return
                }
                if stack[top].afterSpread {
                    // A fragment spread's name.
                    stack[top].afterSpread = false
                    stack[top].pendingField = nil
                    stack[top].pendingFieldType = nil
                    return
                }
                stack[top].pendingField = token.text
                stack[top].pendingCondition = nil
                stack[top].pendingDirective = nil
                stack[top].pendingFieldType = stack[top].typeName.flatMap { parent in
                    schema.fields(of: parent).first { $0.name == token.text }?.type.name
                }
            case .punctuator:
                switch token.text {
                case "(":
                    let owner: GraphQLCompletionSite.ArgumentOwner?
                    if let directive = stack[top].pendingDirective {
                        owner = .directive(name: directive)
                    } else if let field = stack[top].pendingField, let parent = stack[top].typeName {
                        owner = .field(parentType: parent, name: field)
                    } else {
                        owner = nil
                    }
                    stack[top].pendingDirective = nil
                    stack.append(Frame(kind: .arguments, owner: owner))
                case "{":
                    let typeName: String?
                    if let condition = stack[top].pendingCondition {
                        typeName = condition
                    } else if stack[top].afterSpread {
                        typeName = stack[top].typeName
                    } else {
                        typeName = stack[top].pendingFieldType
                    }
                    stack[top].pendingField = nil
                    stack[top].pendingFieldType = nil
                    stack[top].pendingCondition = nil
                    stack[top].afterSpread = false
                    stack.append(Frame(kind: .selection, typeName: typeName))
                case "}":
                    stack.removeLast()
                    if stack.isEmpty {
                        operationFinished = true
                        operation = nil
                        isFragment = false
                        fragmentType = nil
                    } else if stack[stack.count - 1].kind == .selection {
                        stack[stack.count - 1].pendingField = nil
                    }
                case "@":
                    if let next, next.kind == .name {
                        stack[top].pendingDirective = next.text
                        index += 1
                    }
                default:
                    break
                }
            default:
                break
            }
        }

        /// Arguments of a field or directive, and input objects.
        mutating func consumeInValues(_ token: GraphQLToken, next: GraphQLToken?, index: inout Int) {
            let top = stack.count - 1
            switch token.kind {
            case .name:
                if let next, next.isPunctuator(":"), stack[top].currentName == nil || stack[top].valueGiven {
                    stack[top].currentName = token.text
                    stack[top].used.insert(token.text)
                    stack[top].currentType = expectedTypeName(for: token.text, frame: stack[top])
                    stack[top].valueGiven = false
                    index += 1
                } else {
                    stack[top].valueGiven = true
                }
            case .string, .blockString, .number:
                stack[top].valueGiven = true
            case .punctuator:
                switch token.text {
                case "$":
                    if let next, next.kind == .name {
                        index += 1
                    }
                    stack[top].valueGiven = true
                case "[":
                    stack.append(Frame(kind: .list, typeName: stack[top].currentType))
                case "{":
                    stack.append(Frame(kind: .objectValue, typeName: stack[top].currentType))
                case ")", "}":
                    stack.removeLast()
                    markValueGiven()
                default:
                    break
                }
            default:
                break
            }
        }

        mutating func consumeInList(_ token: GraphQLToken, index: inout Int) {
            let top = stack.count - 1
            guard token.kind == .punctuator else { return }
            switch token.text {
            case "[":
                stack.append(Frame(kind: .list, typeName: stack[top].typeName))
            case "{":
                stack.append(Frame(kind: .objectValue, typeName: stack[top].typeName))
            case "]":
                stack.removeLast()
                markValueGiven()
            default:
                break
            }
        }

        mutating func consumeInVariableDefinitions(_ token: GraphQLToken, next: GraphQLToken?, index: inout Int) {
            let top = stack.count - 1
            switch token.kind {
            case .punctuator:
                switch token.text {
                case "$":
                    if let next, next.kind == .name {
                        variables.append(next.text)
                        index += 1
                    }
                    stack[top].inDefault = false
                case "=":
                    stack[top].inDefault = true
                case "{":
                    stack.append(Frame(kind: .objectValue, typeName: nil))
                case "[" where stack[top].inDefault:
                    stack.append(Frame(kind: .list, typeName: nil))
                case ")":
                    stack.removeLast()
                default:
                    break
                }
            default:
                break
            }
        }

        /// A closed list or object is the value of the argument that was waiting for one.
        mutating func markValueGiven() {
            guard !stack.isEmpty else { return }
            let top = stack.count - 1
            switch stack[top].kind {
            case .arguments, .objectValue:
                stack[top].valueGiven = true
            default:
                break
            }
        }

        /// The input type of `name` inside the arguments of a field or directive, or inside an input object.
        func expectedTypeName(for name: String, frame: Frame) -> String? {
            switch frame.kind {
            case .objectValue:
                guard let typeName = frame.typeName else { return nil }
                return schema.types[typeName]?.inputFields.first { $0.name == name }?.type.name
            case .arguments:
                switch frame.owner {
                case .field(let parent, let field):
                    return schema.fields(of: parent).first { $0.name == field }?
                        .arguments.first { $0.name == name }?.type.name
                case .directive(let directive):
                    return schema.directives.first { $0.name == directive }?
                        .arguments.first { $0.name == name }?.type.name
                case nil:
                    return nil
                }
            default:
                return nil
            }
        }

        // MARK: Site

        func currentSite() -> GraphQLCompletionSite? {
            let last = tokens.last
            if let last, last.isPunctuator("@") {
                return .directive
            }
            guard let top = stack.last else {
                if let last, last.isName("on"), isFragment {
                    return .typeCondition(parent: nil)
                }
                if operation == nil, !isFragment {
                    return .operationKeyword
                }
                return nil
            }
            switch top.kind {
            case .selection:
                if let last, last.isName("on"), top.afterSpread {
                    guard let parent = top.typeName else { return nil }
                    return .typeCondition(parent: parent)
                }
                guard let typeName = top.typeName, schema.types[typeName] != nil else {
                    return nil
                }
                if top.afterSpread {
                    return .spread(parentType: typeName)
                }
                if let last, last.isPunctuator("("), top.pendingField != nil {
                    return nil
                }
                return .selection(typeName: typeName, variables: variables)
            case .arguments:
                if top.currentName != nil, !top.valueGiven {
                    return .value(typeName: top.currentType, variables: variables)
                }
                guard let owner = top.owner else { return nil }
                return .argumentName(owner: owner, used: top.used)
            case .objectValue:
                if top.currentName != nil, !top.valueGiven {
                    return .value(typeName: top.currentType, variables: variables)
                }
                guard let typeName = top.typeName, schema.types[typeName]?.kind == .inputObject else { return nil }
                return .objectField(typeName: typeName, used: top.used)
            case .list:
                return .value(typeName: top.typeName, variables: variables)
            case .variableDefinitions:
                if top.inDefault {
                    return nil
                }
                if let last, last.isPunctuator(":") || last.isPunctuator("[") {
                    return .variableType
                }
                return nil
            }
        }
    }
}
