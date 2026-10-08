import EditorIntelligence
import Foundation

/// Which hints ``JavaInlayHintProvider`` produces.
public struct JavaInlayHintOptions: Sendable, Equatable {
    /// `foo(count: 3)`: the name of the parameter an argument is passed to.
    public var parameterNames: Bool
    /// `var items`: ` : List<String>` after a `var` local or loop variable whose type isn't written.
    public var variableTypes: Bool
    /// `(a, b) -> …`: the types of implicitly typed lambda parameters.
    public var lambdaParameterTypes: Bool

    public init(parameterNames: Bool = true, variableTypes: Bool = false, lambdaParameterTypes: Bool = false) {
        self.parameterNames = parameterNames
        self.variableTypes = variableTypes
        self.lambdaParameterTypes = lambdaParameterTypes
    }

    /// Whether any kind of hint is on.
    public var isAnyEnabled: Bool {
        parameterNames || variableTypes || lambdaParameterTypes
    }
}

/// Inlay hints for Java: parameter names at call sites (`foo(count: 3, name: "x")`, shown before the
/// arguments where the name adds information) and, when asked for, the types of `var` locals,
/// `for (var …)` variables and implicit lambda parameters.
///
/// A parameter hint is only produced when the call binds to exactly one declaration with named
/// parameters (class-file stubs without debug info have none), so an overload guess never mislabels
/// an argument. A type hint needs the initializer (or the lambda's target) to type; one that can't
/// be typed, and one whose type the code already says (`new Foo()`, a cast, a literal), get none.
/// Work per request is capped.
public actor JavaInlayHintProvider: InlayHintProviding {
    /// Most calls resolved for one request.
    static let maxCalls = 80
    /// Most declarations typed for one request.
    static let maxTypedDeclarations = 60

    private let index: JavaIndex
    private let indexPaths: JavaIndexPaths
    private var classpathModel: JavaGradleProjectModel?
    private var classpathPaths: JavaIndexPaths?
    private var openBuffer: (@Sendable (URL) async -> String?)?
    private var options = JavaInlayHintOptions()
    private var optionsSource: (@Sendable () -> JavaInlayHintOptions)?

    public init(index: JavaIndex, indexPaths: JavaIndexPaths) {
        self.index = index
        self.indexPaths = indexPaths
    }

    public func setSourceSetClasspath(_ model: JavaGradleProjectModel?, indexPaths: JavaIndexPaths) {
        classpathModel = model
        classpathPaths = model == nil ? nil : indexPaths
    }

    /// Fixed options for every request (the default is parameter names only).
    public func setOptions(_ options: JavaInlayHintOptions) {
        self.options = options
    }

    /// Asks `source` for the options at the start of every request, so a host's settings apply
    /// without being pushed.
    public func setOptionsSource(_ source: (@Sendable () -> JavaInlayHintOptions)?) {
        optionsSource = source
    }

    public func setOpenBufferLookup(_ lookup: (@Sendable (URL) async -> String?)?) {
        openBuffer = lookup
    }

    public func inlayHints(for document: Document, in range: EditorIntelligence.TextRange) async -> [InlayHint] {
        guard document.languageIdentifier == "java" else { return [] }
        let options = optionsSource?() ?? self.options
        guard options.isAnyEnabled else { return [] }
        let source = JavaNavigationText.fullText(of: document)
        guard !source.isEmpty else { return [] }
        let lower = JavaNavigationText.utf8ByteOffset(forUTF16Offset: range.start.utf16Offset, in: source)
        let upper = JavaNavigationText.utf8ByteOffset(forUTF16Offset: range.end.utf16Offset, in: source)
        let lookup = openBuffer
        let url = document.url
        let index = self.index
        let cacheRoot = indexPaths.root
        var scope: Set<String>?
        if let url, let classpathModel, let classpathPaths {
            scope = classpathModel.visibleShardPaths(forFile: url, paths: classpathPaths)
        }
        let work = { () async -> [InlayHint] in
            await JavaInlayHints.compute(
                source: source, fileURL: url, bytes: lower..<max(upper, lower), options: options,
                index: index, cacheRoot: cacheRoot, openBuffer: lookup
            )
        }
        if let scope {
            return await JavaIndex.$queryScope.withValue(scope) {
                await JavaMemberLookup.$sourceTextProvider.withValue(lookup) { await work() }
            }
        }
        return await JavaMemberLookup.$sourceTextProvider.withValue(lookup) { await work() }
    }
}

/// The resolution work, kept out of the actor so the syntax tree never crosses an isolation boundary.
enum JavaInlayHints {
    static func compute(
        source: String, fileURL: URL?, bytes: Range<Int>, options: JavaInlayHintOptions = JavaInlayHintOptions(),
        index: JavaIndex, cacheRoot: URL, openBuffer: (@Sendable (URL) async -> String?)?
    ) async -> [InlayHint] {
        guard let tree = JavaSyntaxParser().parse(source) else { return [] }
        // One stub build for the file; each call or declaration only needs its own scope on top.
        let fileStubs = JavaSourceStubBuilder.build(tree: tree, url: fileURL ?? URL(fileURLWithPath: "/unsaved/Navigation.java"))
        var hints: [InlayHint] = []
        if options.parameterNames {
            var calls: [SyntaxNode] = []
            collectCalls(tree.rootNode, within: bytes, into: &calls)
            for call in calls.prefix(JavaInlayHintProvider.maxCalls) {
                hints.append(contentsOf: await self.hints(
                    for: call, source: source, tree: tree, fileStubs: fileStubs, url: fileURL,
                    index: index, cacheRoot: cacheRoot, openBuffer: openBuffer
                ))
            }
        }
        if options.variableTypes || options.lambdaParameterTypes {
            hints.append(contentsOf: await typeHints(
                source: source, tree: tree, fileStubs: fileStubs, url: fileURL, bytes: bytes, options: options,
                index: index, cacheRoot: cacheRoot, openBuffer: openBuffer
            ))
        }
        return hints
    }

    private static func collectCalls(_ node: SyntaxNode, within bytes: Range<Int>, into calls: inout [SyntaxNode]) {
        guard node.endByte >= bytes.lowerBound, node.startByte <= bytes.upperBound else { return }
        if node.type == "method_invocation" || node.type == "object_creation_expression" {
            calls.append(node)
        }
        for child in node.namedChildren { collectCalls(child, within: bytes, into: &calls) }
    }

    private static func hints(
        for call: SyntaxNode, source: String, tree: JavaSyntaxTree, fileStubs: JavaSourceFileStubs, url: URL?,
        index: JavaIndex, cacheRoot: URL, openBuffer: (@Sendable (URL) async -> String?)?
    ) async -> [InlayHint] {
        guard let arguments = call.child(byFieldName: "arguments") else { return [] }
        let argumentNodes = arguments.namedChildren.filter { $0.type != "line_comment" && $0.type != "block_comment" }
        guard !argumentNodes.isEmpty else { return [] }
        let nameByte: Int
        var typeNode: SyntaxNode?
        if call.type == "method_invocation" {
            guard let name = call.child(byFieldName: "name") else { return [] }
            nameByte = name.startByte
        } else {
            guard let type = call.child(byFieldName: "type") else { return [] }
            typeNode = type.type == "generic_type" ? (type.namedChild(at: 0) ?? type) : type
            nameByte = type.startByte
        }
        let session = JavaNavigationSession(
            source: source, fileURL: url, tree: tree, byteOffset: nameByte, fileStubs: fileStubs,
            index: index, jdkHome: nil, cacheRoot: cacheRoot, openBuffer: openBuffer,
            decompile: JavaDecompileGate(policy: .denied)
        )
        let method: JavaMethodStub
        if let typeNode {
            let symbols = await session.resolveSymbols(.constructor(type: typeNode, argumentCount: argumentNodes.count))
            guard symbols.count == 1, case .method(let stub, _) = symbols[0] else { return [] }
            method = stub
        } else {
            let targets = await session.methodCallTargets(call)
            guard targets.count == 1 else { return [] }
            method = targets[0].method
        }
        return hints(arguments: argumentNodes, method: method, source: source)
    }

    /// The hints for `arguments` bound to `method`'s parameters. Varargs, unnamed parameters and
    /// arguments that already say what they are get none.
    static func hints(arguments: [SyntaxNode], method: JavaMethodStub, source: String) -> [InlayHint] {
        let parameters = method.parameters
        guard !parameters.isEmpty, parameters.allSatisfy({ $0.name?.isEmpty == false }) else { return [] }
        if arguments.count == 1, isObviousSingleArgument(method) { return [] }
        let isVarargs = method.modifiers.contains(.varargs)
        var hints: [InlayHint] = []
        for (position, argument) in arguments.enumerated() {
            if position >= parameters.count { break }
            if isVarargs && position >= parameters.count - 1 { break }
            guard let name = parameters[position].name, shouldHint(argument, parameterName: name) else { continue }
            hints.append(InlayHint(
                utf16Offset: JavaNavigationText.utf16Offset(forByte: argument.startByte, in: source),
                label: "\(name):"
            ))
        }
        return hints
    }

    /// Lambdas and method references read fine; a plain name equal to the parameter says it already.
    static func shouldHint(_ argument: SyntaxNode, parameterName: String) -> Bool {
        switch argument.type {
        case "lambda_expression", "method_reference":
            return false
        case "identifier":
            return argument.text != parameterName
        case "field_access":
            return argument.child(byFieldName: "field")?.text != parameterName
        default:
            return true
        }
    }

    /// `setName("x")`, `add(x)`, `of(1)`: one argument whose meaning the method name already gives.
    private static func isObviousSingleArgument(_ method: JavaMethodStub) -> Bool {
        let name = method.name
        for prefix in ["set", "with", "add", "is", "has"] where name.hasPrefix(prefix) { return true }
        return ["of", "valueOf", "println", "print", "append", "get", "put", "remove", "contains", "equals", "compare", "asList"].contains(name)
    }

    // MARK: - Type hints

    /// A declaration whose type isn't written: where its name ends, and the byte offset whose locals
    /// include it.
    private struct TypeCandidate {
        let name: SyntaxNode
        let scopeOffset: Int
    }

    private static func typeHints(
        source: String, tree: JavaSyntaxTree, fileStubs: JavaSourceFileStubs, url: URL?, bytes: Range<Int>,
        options: JavaInlayHintOptions, index: JavaIndex, cacheRoot: URL, openBuffer: (@Sendable (URL) async -> String?)?
    ) async -> [InlayHint] {
        var candidates: [TypeCandidate] = []
        collectTypeCandidates(tree.rootNode, within: bytes, options: options, into: &candidates)
        var hints: [InlayHint] = []
        // Candidates in one block share a scope, so their `var` initializers are typed once.
        var resolvedByScope: [Int: [JavaLocalVariable]] = [:]
        for candidate in candidates.prefix(JavaInlayHintProvider.maxTypedDeclarations) {
            let resolved: [JavaLocalVariable]
            if let cached = resolvedByScope[candidate.scopeOffset] {
                resolved = cached
            } else {
                let session = JavaNavigationSession(
                    source: source, fileURL: url, tree: tree, byteOffset: candidate.scopeOffset, fileStubs: fileStubs,
                    index: index, jdkHome: nil, cacheRoot: cacheRoot, openBuffer: openBuffer,
                    decompile: JavaDecompileGate(policy: .denied)
                )
                resolved = await JavaExpressionTyper.resolvingVarLocals(
                    JavaLocalScope.locals(in: tree, atByteOffset: candidate.scopeOffset),
                    context: session.context, index: index
                )
                resolvedByScope[candidate.scopeOffset] = resolved
            }
            guard let local = resolved.first(where: { $0.name == candidate.name.text }),
                  !local.isVarDeclaration, local.lambdaOrigin == nil, isInformative(local.type) else { continue }
            hints.append(InlayHint(
                utf16Offset: JavaNavigationText.utf16Offset(forByte: candidate.name.endByte, in: source),
                label: ": " + JavaSignatureText.text(of: local.type),
                kind: .type
            ))
        }
        return hints
    }

    /// `Object` is what a failed inference falls back to; a hint saying so would mislead.
    private static func isInformative(_ type: JavaTypeRef) -> Bool {
        if case .unresolved(let name, _) = type { return name != "Object" && name != "var" && !name.isEmpty }
        return type.simpleDisplayName != "Object"
    }

    private static func collectTypeCandidates(
        _ node: SyntaxNode, within bytes: Range<Int>, options: JavaInlayHintOptions, into candidates: inout [TypeCandidate]
    ) {
        guard node.endByte >= bytes.lowerBound, node.startByte <= bytes.upperBound else { return }
        switch node.type {
        case "local_variable_declaration" where options.variableTypes:
            if node.child(byFieldName: "type")?.text == "var" {
                let scope = scopeOffset(forDeclaration: node)
                for declarator in node.namedChildren(ofType: "variable_declarator") {
                    guard let name = declarator.child(byFieldName: "name"),
                          let value = declarator.child(byFieldName: "value"), !typeIsObvious(from: value) else { continue }
                    candidates.append(TypeCandidate(name: name, scopeOffset: scope))
                }
            }
        case "enhanced_for_statement" where options.variableTypes:
            if node.child(byFieldName: "type")?.text == "var",
               let name = node.child(byFieldName: "name"), let body = node.child(byFieldName: "body") {
                candidates.append(TypeCandidate(name: name, scopeOffset: body.startByte))
            }
        case "lambda_expression" where options.lambdaParameterTypes:
            if let body = node.child(byFieldName: "body"), let parameters = node.child(byFieldName: "parameters") {
                let names: [SyntaxNode]
                if parameters.type == "inferred_parameters" {
                    names = parameters.namedChildren.filter { $0.type == "identifier" }
                } else if parameters.type == "identifier" {
                    names = [parameters]
                } else {
                    names = []
                }
                for name in names {
                    candidates.append(TypeCandidate(name: name, scopeOffset: body.startByte))
                }
            }
        default:
            break
        }
        for child in node.namedChildren { collectTypeCandidates(child, within: bytes, options: options, into: &candidates) }
    }

    /// The offset whose locals include a `var` declared in `declaration`: the end of its block (so
    /// every `var` of the block is typed together), or just after the declaration where the variable
    /// belongs to a `for` header or a `switch` group.
    private static func scopeOffset(forDeclaration declaration: SyntaxNode) -> Int {
        if let parent = declaration.parent, parent.type == "block" || parent.type == "constructor_body" {
            return max(parent.endByte - 1, parent.startByte)
        }
        return declaration.endByte
    }

    /// The initializer already says the type: `new Foo<>()`, a cast, a literal, a factory on the named type.
    static func typeIsObvious(from value: SyntaxNode) -> Bool {
        switch value.type {
        case "object_creation_expression", "cast_expression", "array_creation_expression", "string_literal",
             "character_literal", "true", "false", "null_literal", "text_block":
            return true
        case "decimal_integer_literal", "hex_integer_literal", "octal_integer_literal", "binary_integer_literal",
             "decimal_floating_point_literal", "hex_floating_point_literal":
            return true
        case "method_invocation":
            guard let object = value.child(byFieldName: "object"), object.type == "identifier",
                  object.text.first?.isUppercase == true, let name = value.child(byFieldName: "name") else { return false }
            return ["of", "valueOf", "from", "create", "newInstance", "getInstance"].contains(name.text)
        default:
            return false
        }
    }
}
