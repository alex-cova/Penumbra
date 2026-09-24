import EditorIntelligence
import Foundation

/// Parameter-name hints at Java call sites: `foo(count: 3, name: "x")`, shown before the
/// arguments where the name adds information.
///
/// A hint is only produced when the call binds to exactly one declaration with named parameters
/// (class-file stubs without debug info have none), so an overload guess never mislabels an
/// argument. Work per request is capped.
public actor JavaInlayHintProvider: InlayHintProviding {
    /// Most calls resolved for one request.
    static let maxCalls = 80

    private let index: JavaIndex
    private let indexPaths: JavaIndexPaths
    private var classpathModel: JavaGradleProjectModel?
    private var classpathPaths: JavaIndexPaths?
    private var openBuffer: (@Sendable (URL) async -> String?)?

    public init(index: JavaIndex, indexPaths: JavaIndexPaths) {
        self.index = index
        self.indexPaths = indexPaths
    }

    public func setSourceSetClasspath(_ model: JavaGradleProjectModel?, indexPaths: JavaIndexPaths) {
        classpathModel = model
        classpathPaths = model == nil ? nil : indexPaths
    }

    public func setOpenBufferLookup(_ lookup: (@Sendable (URL) async -> String?)?) {
        openBuffer = lookup
    }

    public func inlayHints(for document: Document, in range: EditorIntelligence.TextRange) async -> [InlayHint] {
        guard document.languageIdentifier == "java" else { return [] }
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
                source: source, fileURL: url, bytes: lower..<max(upper, lower),
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
        source: String, fileURL: URL?, bytes: Range<Int>, index: JavaIndex, cacheRoot: URL,
        openBuffer: (@Sendable (URL) async -> String?)?
    ) async -> [InlayHint] {
        guard let tree = JavaSyntaxParser().parse(source) else { return [] }
        var calls: [SyntaxNode] = []
        collectCalls(tree.rootNode, within: bytes, into: &calls)
        var hints: [InlayHint] = []
        for call in calls.prefix(JavaInlayHintProvider.maxCalls) {
            hints.append(contentsOf: await self.hints(
                for: call, source: source, tree: tree, url: fileURL, index: index, cacheRoot: cacheRoot, openBuffer: openBuffer
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
        for call: SyntaxNode, source: String, tree: JavaSyntaxTree, url: URL?, index: JavaIndex, cacheRoot: URL,
        openBuffer: (@Sendable (URL) async -> String?)?
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
            source: source, fileURL: url, tree: tree, byteOffset: nameByte,
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
}
