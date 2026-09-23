import EditorIntelligence
import Foundation

/// Relevance buckets for ``CompletionItem/priority``, highest first -- the ordering IntelliJ uses
/// within one match tier: locals, then members declared by the receiver's own class, inherited
/// members, and `Object`'s members last.
enum JavaCompletionPriority {
    static let local = 4.0
    static let ownMember = 3.0
    static let inheritedMember = 2.0
    static let staticImport = 2.0
    static let outerMember = 1.5
    static let classInScope = 1.5
    static let classOther = 1.0
    static let keyword = 0.5
    static let objectMember = 0.25
    static let deprecatedPenalty = -3.0
    static let expectedTypeBonus = 5.0
}

/// Builds ``CompletionItem``s for Java members, locals, classes and keywords with IntelliJ-style
/// presentation: the method's parameter list as the dimmed tail, its return type (or a field's
/// type, or a class's package) on the right, deprecated items struck through.
struct JavaCompletionItemFactory {
    let range: EditorIntelligence.TextRange
    let source: String

    // MARK: - Members

    func memberItem(
        _ member: JavaResolvedMember, receiverQualifiedName: String?, basePriority: Double? = nil,
        expectedMatch: Bool = false, asMethodReference: Bool = false
    ) -> CompletionItem {
        let declaringClass = member.declaringClass
        var priority: Double
        if let basePriority {
            priority = basePriority
        } else if declaringClass == "java.lang.Object" {
            priority = JavaCompletionPriority.objectMember
        } else if declaringClass == receiverQualifiedName || receiverQualifiedName == nil {
            priority = JavaCompletionPriority.ownMember
        } else {
            priority = JavaCompletionPriority.inheritedMember
        }
        let deprecated = member.modifiers.contains(.deprecatedFlag)
        if deprecated { priority += JavaCompletionPriority.deprecatedPenalty }
        if expectedMatch { priority += JavaCompletionPriority.expectedTypeBonus }

        switch member {
        case .field(let field, _):
            return CompletionItem(
                label: field.name,
                insertText: field.name,
                kind: field.modifiers.contains(.enumConstant) ? .enumMember : .field,
                range: range,
                source: source,
                documentation: field.javadoc,
                detail: Self.display(field.type),
                isDeprecated: deprecated,
                priority: priority,
                preselect: expectedMatch
            )
        case .method(let method, _):
            let hasParameters = !method.parameters.isEmpty
            let insertText = asMethodReference ? method.name : "\(method.name)()"
            return CompletionItem(
                label: method.name,
                insertText: insertText,
                kind: .method,
                range: range,
                source: source,
                documentation: method.javadoc,
                filterText: method.name,
                detail: Self.display(method.returnType),
                labelDetail: Self.parameterList(method),
                isDeprecated: deprecated,
                priority: priority,
                caretOffset: !asMethodReference && hasParameters ? (method.name as NSString).length + 1 : nil,
                triggersSignatureHelp: !asMethodReference && hasParameters,
                preselect: expectedMatch
            )
        }
    }

    func localItem(_ local: JavaLocalVariable, expectedMatch: Bool) -> CompletionItem {
        CompletionItem(
            label: local.name,
            insertText: local.name,
            kind: .variable,
            range: range,
            source: source,
            detail: local.isVarDeclaration ? nil : Self.display(local.type),
            priority: JavaCompletionPriority.local + (expectedMatch ? JavaCompletionPriority.expectedTypeBonus : 0),
            preselect: expectedMatch
        )
    }

    // MARK: - Classes

    func classItem(
        _ stub: JavaClassStub, importDecision: JavaImportInserter.Decision, priority: Double, expectedMatch: Bool = false
    ) -> CompletionItem {
        var edits: [TextEdit] = []
        var insertText = stub.simpleName
        switch importDecision {
        case .none:
            break
        case .addImport(let edit):
            edits = [edit]
        case .useQualifiedName:
            insertText = stub.qualifiedName
        }
        let deprecated = stub.modifiers.contains(.deprecatedFlag)
        var finalPriority = priority
        if deprecated { finalPriority += JavaCompletionPriority.deprecatedPenalty }
        if expectedMatch { finalPriority += JavaCompletionPriority.expectedTypeBonus }
        return CompletionItem(
            label: stub.simpleName,
            insertText: insertText,
            kind: Self.kind(of: stub),
            range: range,
            source: source,
            documentation: stub.javadoc,
            filterText: stub.simpleName,
            detail: nil,
            labelDetail: Self.classTail(stub),
            isDeprecated: deprecated,
            additionalEdits: edits,
            priority: finalPriority,
            preselect: expectedMatch
        )
    }

    /// `new Foo|` → `Foo()` / `Foo<>()`, caret inside the parentheses when a constructor takes
    /// arguments.
    func constructorItem(
        _ stub: JavaClassStub, importDecision: JavaImportInserter.Decision, priority: Double, expectedMatch: Bool
    ) -> CompletionItem {
        var name = stub.simpleName
        var edits: [TextEdit] = []
        switch importDecision {
        case .none: break
        case .addImport(let edit): edits = [edit]
        case .useQualifiedName: name = stub.qualifiedName
        }
        let constructors = stub.methods.filter { $0.isConstructor && !$0.modifiers.contains(.privateFlag) }
        let diamond = stub.typeParameters.isEmpty ? "" : "<>"
        let takesArguments = constructors.contains { !$0.parameters.isEmpty }
        let insertText = "\(name)\(diamond)()"
        let tail: String
        if constructors.count == 1, let only = constructors.first {
            tail = "\(Self.parameterList(only))\(Self.classTail(stub))"
        } else {
            tail = Self.classTail(stub)
        }
        let deprecated = stub.modifiers.contains(.deprecatedFlag)
        var finalPriority = priority
        if stub.kind == .interfaceKind || stub.modifiers.contains(.abstractFlag) { finalPriority -= 1 }
        if deprecated { finalPriority += JavaCompletionPriority.deprecatedPenalty }
        if expectedMatch { finalPriority += JavaCompletionPriority.expectedTypeBonus }
        return CompletionItem(
            label: stub.simpleName,
            insertText: insertText,
            kind: Self.kind(of: stub),
            range: range,
            source: source,
            documentation: stub.javadoc,
            filterText: stub.simpleName,
            labelDetail: tail,
            isDeprecated: deprecated,
            additionalEdits: edits,
            priority: finalPriority,
            caretOffset: takesArguments ? (insertText as NSString).length - 1 : nil,
            triggersSignatureHelp: takesArguments,
            preselect: expectedMatch
        )
    }

    func packageItem(_ qualifiedPackage: String) -> CompletionItem {
        let segment = String(qualifiedPackage.split(separator: ".").last ?? Substring(qualifiedPackage))
        return CompletionItem(
            label: segment, insertText: segment, kind: .package, range: range, source: source,
            detail: qualifiedPackage, priority: JavaCompletionPriority.classInScope
        )
    }

    func keywordItem(_ keyword: String, priority: Double = JavaCompletionPriority.keyword, insertText: String? = nil) -> CompletionItem {
        CompletionItem(
            label: keyword, insertText: insertText ?? keyword, kind: .keyword, range: range, source: source,
            priority: priority
        )
    }

    /// An `@Override` stub for a supertype method, inserted as a snippet with the caret in its body.
    func overrideItem(_ method: JavaMethodStub, declaringClass: String, isInterfaceMethod: Bool, indentation: String) -> CompletionItem {
        let visibility = method.modifiers.contains(.publicFlag) || isInterfaceMethod ? "public " : method.modifiers.contains(.protectedFlag) ? "protected " : ""
        var parameterNames: [String] = []
        let parameters = method.parameters.enumerated().map { position, parameter -> String in
            let name = parameter.name ?? Self.defaultParameterName(for: parameter.type, position: position)
            parameterNames.append(name)
            let isVarargs = method.modifiers.contains(.varargs) && position == method.parameters.count - 1
            if isVarargs, case .array(let element) = parameter.type {
                return "\(Self.display(element))... \(name)"
            }
            return "\(Self.display(parameter.type)) \(name)"
        }
        let typeParameters = method.typeParameters.isEmpty ? "" : "<\(method.typeParameters.map(\.name).joined(separator: ", "))> "
        let signature = "\(visibility)\(typeParameters)\(Self.display(method.returnType)) \(method.name)(\(parameters.joined(separator: ", ")))"
        let isAbstract = method.modifiers.contains(.abstractFlag) || (isInterfaceMethod && !method.modifiers.contains(.defaultMethod))
        let body: String
        if isAbstract {
            body = Self.defaultReturnStatement(for: method.returnType).map { "$0\($0)" } ?? "$0"
        } else {
            let call = "super.\(Self.escapeSnippet(method.name))(\(parameterNames.map(Self.escapeSnippet).joined(separator: ", ")))"
            body = method.returnType == .void ? "\(call);$0" : "return \(call);$0"
        }
        let unit = "    "
        let snippet = "@Override\n\(indentation)\(Self.escapeSnippet(signature)) {\n\(indentation)\(unit)\(body)\n\(indentation)}"
        return CompletionItem(
            label: method.name,
            insertText: snippet,
            kind: .method,
            range: range,
            source: source,
            documentation: method.javadoc,
            filterText: method.name,
            detail: isAbstract ? "implement" : "override",
            labelDetail: Self.parameterList(method),
            insertTextIsSnippet: true,
            priority: JavaCompletionPriority.inheritedMember
        )
    }

    // MARK: - Display

    static func kind(of stub: JavaClassStub) -> CompletionItemKind {
        switch stub.kind {
        case .classKind, .recordKind: return .class
        case .interfaceKind: return .interface
        case .enumKind: return .enum
        case .annotationKind: return .annotation
        }
    }

    static func classTail(_ stub: JavaClassStub) -> String {
        let generics = stub.typeParameters.isEmpty ? "" : "<\(stub.typeParameters.map(\.name).joined(separator: ", "))>"
        let owner = stub.outerQualifiedName ?? stub.packageName
        return owner.isEmpty ? generics : "\(generics) (\(owner))"
    }

    /// `(String s, int n)`; parameter names are left out when the class file didn't keep them.
    static func parameterList(_ method: JavaMethodStub) -> String {
        let parts = method.parameters.enumerated().map { position, parameter -> String in
            var type = display(parameter.type)
            if method.modifiers.contains(.varargs), position == method.parameters.count - 1, case .array(let element) = parameter.type {
                type = "\(display(element))..."
            }
            if let name = parameter.name { return "\(type) \(name)" }
            return type
        }
        return "(\(parts.joined(separator: ", ")))"
    }

    /// A readable type with generic arguments: `List<String>`, `Map<K, V>`, `? extends T`, `int[]`.
    static func display(_ type: JavaTypeRef) -> String {
        switch type {
        case .primitive(let p): return p.rawValue
        case .void: return "void"
        case .typeVariable(let name): return name
        case .array(let element): return "\(display(element))[]"
        case .wildcard(let bound): return display(bound)
        case .classType(let qualifiedName, let arguments, _):
            let simple = String(qualifiedName.split(separator: ".").last ?? Substring(qualifiedName))
            return arguments.isEmpty ? simple : "\(simple)<\(arguments.map(display).joined(separator: ", "))>"
        case .unresolved(let simpleName, let arguments):
            return arguments.isEmpty ? simpleName : "\(simpleName)<\(arguments.map(display).joined(separator: ", "))>"
        }
    }

    private static func display(_ argument: JavaTypeArgument) -> String {
        switch argument {
        case .type(let t): return display(t)
        case .wildcard(let bound): return display(bound)
        }
    }

    private static func display(_ bound: JavaWildcardBound?) -> String {
        switch bound {
        case nil: return "?"
        case .extends(let t)?: return "? extends \(display(t))"
        case .superBound(let t)?: return "? super \(display(t))"
        }
    }

    private static func defaultParameterName(for type: JavaTypeRef, position: Int) -> String {
        let base = display(type).prefix { $0.isLetter || $0.isNumber }
        guard let first = base.first else { return "arg\(position)" }
        let name = first.lowercased() + base.dropFirst()
        return ["int", "long", "short", "byte", "char", "float", "double", "boolean"].contains(name) ? "\(name.prefix(1))\(position)" : name
    }

    private static func defaultReturnStatement(for type: JavaTypeRef) -> String? {
        switch type {
        case .void: return nil
        case .primitive(.boolean): return "return false;"
        case .primitive: return "return 0;"
        default: return "return null;"
        }
    }

    /// ``SnippetParser`` reads `$$` as a literal `$` (Java identifiers may contain `$`).
    static func escapeSnippet(_ text: String) -> String {
        text.replacingOccurrences(of: "$", with: "$$")
    }
}
