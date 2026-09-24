import EditorIntelligence
import Foundation
import os

private let javaCompletionLog = Logger(subsystem: "Penumbra", category: "Completion")

/// The `EditorIntelligence.CompletionProvider` that turns everything the rest of `JavaIntelligence`
/// builds (the index, type resolution, member lookup, expression typing) into IntelliJ-style
/// completion for a Java document. Active only for `languageIdentifier == "java"`, where it claims
/// the document as primary (see ``CompletionProvider/isPrimary(for:)``) so generic word/snippet
/// suggestions only fill in when it has nothing to say.
///
/// ``JavaCompletionContextClassifier`` decides the site first, and each site gets its own
/// candidates:
/// - **Member access** (`foo.|`): the receiver's members (instance or static), nested types and
///   `class` after a type, subpackages and classes after a package prefix (`java.util.|`).
/// - **Statement position**: locals, implicit-`this` members (static-only in a static context),
///   statically imported members, classes (auto-imported on accept), context keywords.
/// - **`new |`**: classes with their constructor, `<>` for generics, caret in the parentheses.
/// - **`@|`**: annotation types; `@Foo(|` offers the annotation's attributes.
/// - **`import`/`package`**: packages and classes.
/// - **Type-only positions** (`extends`, `implements`, `throws`, `catch (`): classes/interfaces.
/// - **`case |`**: the enum constants of the switch selector's type.
/// - **Class body**: modifiers, types, and `@Override` stubs for supertype methods.
///
/// Items are not prefix-filtered here beyond cheap pre-filtering: ``DefaultRanker`` does
/// IntelliJ-style camel-hump matching and orders by ``CompletionItem/priority``, which this
/// provider sets (locals > own members > inherited > `Object`, deprecated down, expected type up).
public actor JavaCompletionProvider: CompletionProvider {
    public let name = "Java"
    private let index: JavaIndex
    private let classNameCompletionLimit: Int
    /// Set after a Gradle sync. Nil keeps every indexed shard visible (non-Gradle folders, and the
    /// whole-tree fallback while the first sync is still running).
    private var classpathModel: JavaGradleProjectModel?
    private var classpathPaths: JavaIndexPaths?
    /// The last parse, reused when the same text is completed again (re-filtering, a second
    /// Ctrl+Space).
    private var cachedParse: (text: String, tree: JavaSyntaxTree, stubs: JavaSourceFileStubs)?
    private var lastParseURL: URL?
    /// Owned by this actor, so never used by two parses at once.
    private let parser = JavaSyntaxParser()

    public init(index: JavaIndex, classNameCompletionLimit: Int = 100) {
        self.index = index
        self.classNameCompletionLimit = classNameCompletionLimit
    }

    /// Installs or clears the source-set classpath used to scope completion. `nil` sees every shard.
    public func setSourceSetClasspath(_ model: JavaGradleProjectModel?, indexPaths: JavaIndexPaths) {
        classpathModel = model
        classpathPaths = model == nil ? nil : indexPaths
    }

    public nonisolated func isPrimary(for context: CompletionContext) -> Bool {
        context.document.languageIdentifier == "java"
    }

    public func provide(context: CompletionContext) async -> [CompletionItem] {
        var items: [CompletionItem] = []
        for await update in provideUpdates(context: context) {
            items = update.items
        }
        return items
    }

    public nonisolated func provideUpdates(context: CompletionContext) -> AsyncStream<CompletionUpdate> {
        AsyncStream { continuation in
            let task = Task {
                let updates = await self.updates(for: context)
                for update in updates {
                    if Task.isCancelled { break }
                    continuation.yield(update)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func updates(for context: CompletionContext) async -> [CompletionUpdate] {
        guard context.document.languageIdentifier == "java" else {
            return [CompletionUpdate(items: [], isFinished: true)]
        }
        // A second Ctrl+Space looks past the source set's classpath, like IntelliJ's second
        // basic-completion invocation.
        if context.invocationCount < 2, let scope = scope(for: context.document.url) {
            return await JavaIndex.$queryScope.withValue(scope) {
                await self.provideInScope(context: context)
            }
        }
        return await provideInScope(context: context)
    }

    func scope(for file: URL?) -> Set<String>? {
        guard let file, let classpathModel, let classpathPaths else { return nil }
        return classpathModel.visibleShardPaths(forFile: file, paths: classpathPaths)
    }

    var javaIndex: JavaIndex {
        index
    }

    func parse(_ text: String, url: URL) -> (tree: JavaSyntaxTree, stubs: JavaSourceFileStubs)? {
        if let cachedParse, cachedParse.text == text {
            return (cachedParse.tree, cachedParse.stubs)
        }
        guard let tree = incrementalParse(text, url: url) ?? parser.parse(text) else { return nil }
        let stubs = JavaSourceStubBuilder.build(tree: tree, url: url)
        cachedParse = (text, tree, stubs)
        lastParseURL = url
        return (tree, stubs)
    }

    /// Consecutive requests in one document differ by what was typed plus where the dummy
    /// identifier sits, so the previous tree is reused: the difference becomes one tree-sitter
    /// edit on a copy of it (an earlier request suspended mid-lookup may still be reading the
    /// original) and only the changed region is reparsed.
    private func incrementalParse(_ text: String, url: URL) -> JavaSyntaxTree? {
        guard let cachedParse, lastParseURL == url else { return nil }
        let newBytes = Array(text.utf8)
        guard let edit = JavaParseEdit.diff(from: cachedParse.tree.sourceBytes, to: newBytes) else { return cachedParse.tree }
        let edited = cachedParse.tree.copy()
        edited.apply(edit)
        return parser.parseIncremental(oldTree: edited, source: text)
    }

    // MARK: - Request

    /// Everything one completion request works from.
    private struct Request {
        let text: String
        let bytes: [UInt8]
        let tree: JavaSyntaxTree
        let fileStubs: JavaSourceFileStubs
        let prefix: String
        let prefixStart: Int
        let cursor: Int
        let context: JavaResolutionContext
        let factory: JavaCompletionItemFactory
        let importer: JavaImportInserter
        let invocationCount: Int
        let mode: CompletionMode
        let isManual: Bool

        var semantic: JavaSemanticRequest {
            JavaSemanticRequest(source: text, bytes: bytes, tree: tree, locals: [], context: context, index: index)
        }
        let index: JavaIndex
    }

    /// Inserted at the caret before parsing, like IntelliJ's dummy identifier: `this.` or
    /// `new ` followed by nothing makes tree-sitter collapse the enclosing declaration into an
    /// `ERROR` node, while `this.__penumbra__` parses cleanly. Offsets before the caret are
    /// unchanged, which is all completion looks at.
    static let dummyIdentifier = "__penumbra__"

    /// `text` with ``dummyIdentifier`` inserted at `utf16Offset`. When nothing but whitespace
    /// follows the caret on its line (typing `products.` at the end of a line), a `;` closes the
    /// statement too: otherwise `products.__penumbra__` runs into the next line's statement and
    /// tree-sitter's error recovery can re-shape the surrounding methods, putting the caret in
    /// the wrong one.
    static func repairedText(_ text: String, insertingDummyAt utf16Offset: Int) -> String {
        let ns = text as NSString
        let location = min(max(0, utf16Offset), ns.length)
        let restOfLine = ns.substring(from: location).prefix { $0 != "\n" && $0 != "\r\n" }
        let closesStatement = restOfLine.allSatisfy { $0 == " " || $0 == "\t" } && isInsideMethodBody(ns.substring(to: location))
        return ns.substring(to: location) + dummyIdentifier + (closesStatement ? ";" : "") + ns.substring(from: location)
    }

    /// Cheap check that the caret is inside a block rather than at class-body level, where a
    /// stray `;` would be harmless anyway but a member declaration (`private Str|`) must not end.
    private static func isInsideMethodBody(_ before: String) -> Bool {
        var depth = 0
        var methodDepths: [Int] = []
        var previousSignificant: Character = " "
        for character in before {
            switch character {
            case "{":
                depth += 1
                // `) {` / `-> {` / `else {` open code blocks; `class X {` opens a type body.
                if previousSignificant == ")" || previousSignificant == ">" || !methodDepths.isEmpty {
                    methodDepths.append(depth)
                }
            case "}":
                if methodDepths.last == depth { methodDepths.removeLast() }
                depth -= 1
            default:
                break
            }
            if !character.isWhitespace { previousSignificant = character }
        }
        return !methodDepths.isEmpty
    }

    private func makeRequest(context: CompletionContext) -> Request? {
        // Open project files are file-backed: the snapshot keeps the bytes behind a range reader
        // and `text` is nil. Completion still has to parse the buffer the caret is in.
        let text = Self.repairedText(
            JavaNavigationText.fullText(of: context.document),
            insertingDummyAt: context.cursor.position.utf16Offset
        )
        let fileURL = context.document.url ?? URL(fileURLWithPath: "/unsaved/\(context.document.id).java")
        guard let (tree, fileStubs) = parse(text, url: fileURL) else { return nil }

        let bytes = Array(text.utf8)
        let prefixStart = Self.utf8ByteOffset(forUTF16Offset: context.range.start.utf16Offset, in: text)
        let cursor = Self.utf8ByteOffset(forUTF16Offset: context.cursor.position.utf16Offset, in: text)
        let resolutionContext = Self.resolutionContext(in: tree, fileStubs: fileStubs, atByteOffset: min(prefixStart, cursor))
        return Request(
            text: text, bytes: bytes, tree: tree, fileStubs: fileStubs, prefix: context.prefix,
            prefixStart: prefixStart, cursor: cursor, context: resolutionContext,
            factory: JavaCompletionItemFactory(range: context.range, source: name),
            importer: JavaImportInserter(text: text, bytes: bytes, tree: tree, fileStubs: fileStubs),
            invocationCount: context.invocationCount,
            mode: context.mode,
            isManual: context.trigger == .manual,
            index: index
        )
    }

    /// What one request classified and resolved, without building items: the completion corpus
    /// scorecard checks these separately from the candidate list.
    struct Diagnosis {
        let site: JavaCompletionSite
        let receiverType: JavaTypeRef?
        let receiverIsTypeReference: Bool
        let expected: [JavaTypeRef]
    }

    func diagnose(context: CompletionContext) async -> Diagnosis? {
        guard let request = makeRequest(context: context) else { return nil }
        let site = JavaCompletionContextClassifier.classify(bytes: request.bytes, tree: request.tree, prefixStart: request.prefixStart)
        var receiverType: JavaTypeRef?
        var isTypeReference = false
        var expected: [JavaTypeRef] = []
        switch site {
        case .memberAccess(let dotOffset):
            let receiver = await JavaExpressionTyper.receiverInfo(
                source: request.text, realTree: request.tree, dotOffset: dotOffset, context: request.context, index: index
            )
            receiverType = receiver?.type
            isTypeReference = receiver?.isTypeReference ?? false
            expected = await JavaExpectedType.infer(
                at: Self.expressionStart(beforeDot: dotOffset, bytes: request.bytes, source: request.text), request: request.semantic
            )
        case .methodReference(let colonOffset):
            var bytes = request.bytes
            bytes[colonOffset] = UInt8(ascii: " ")
            bytes[colonOffset + 1] = UInt8(ascii: ".")
            let receiver = await JavaExpressionTyper.receiverInfo(
                source: String(decoding: bytes, as: UTF8.self), realTree: request.tree, dotOffset: colonOffset + 1,
                context: request.context, index: index
            )
            receiverType = receiver?.type
            isTypeReference = receiver?.isTypeReference ?? false
        case .newExpression:
            expected = await JavaExpectedType.infer(at: Self.newKeywordStart(before: request.prefixStart, bytes: request.bytes), request: request.semantic)
        case .statement, .caseLabel:
            let locals = await JavaExpressionTyper.resolvingVarLocals(
                JavaLocalScope.locals(in: request.tree, atByteOffset: request.cursor), context: request.context, index: index
            )
            let semantic = JavaSemanticRequest(
                source: request.text, bytes: request.bytes, tree: request.tree, locals: locals, context: request.context, index: index
            )
            expected = await JavaExpectedType.infer(at: request.prefixStart, request: semantic)
        default:
            break
        }
        return Diagnosis(site: site, receiverType: receiverType, receiverIsTypeReference: isTypeReference, expected: expected)
    }

    private func provideInScope(context: CompletionContext) async -> [CompletionUpdate] {
        guard let request = makeRequest(context: context) else { return finished([]) }
        let bytes = request.bytes
        let tree = request.tree
        let text = request.text
        let prefixStart = request.prefixStart
        let resolutionContext = request.context

        let site = JavaCompletionContextClassifier.classify(bytes: bytes, tree: tree, prefixStart: prefixStart)
        javaCompletionLog.debug("java site=\(String(describing: site), privacy: .public) enclosing=\(resolutionContext.enclosingTypeQualifiedNames, privacy: .public)")
        switch site {
        case .stringOrComment:
            return finished([])
        case .memberAccess(let dotOffset):
            return finished(await memberAccessItems(dotOffset: dotOffset, source: text, request: request))
        case .methodReference(let colonOffset):
            return finished(await methodReferenceItems(colonOffset: colonOffset, request: request))
        case .importPath(let qualifier, let isStatic):
            return finished(await importItems(qualifier: qualifier, isStatic: isStatic, request: request))
        case .packagePath(let qualifier):
            return finished(await index.subpackages(of: qualifier).map { request.factory.packageItem($0) })
        case .annotation:
            return await annotationUpdates(request: request)
        case .annotationAttribute(let annotationName):
            return finished(await annotationAttributeItems(annotationName: annotationName, request: request))
        case .newExpression:
            return await newExpressionUpdates(request: request)
        case .typeOnly(let keyword):
            return await typeOnlyUpdates(keyword: keyword, request: request)
        case .caseLabel(let selectorText):
            let items = await caseLabelItems(selectorText: selectorText, request: request)
            if !items.isEmpty { return finished(items) }
            return await statementUpdates(request: request)
        case .classBody:
            return await classBodyUpdates(request: request)
        case .topLevel:
            return finished(Self.topLevelKeywords.map { request.factory.keywordItem($0) })
        case .statement:
            return await statementUpdates(request: request)
        case .cast:
            return await castUpdates(request: request)
        }
    }

    private func finished(_ items: [CompletionItem], advertisement: String? = nil, emptyText: String? = nil) -> [CompletionUpdate] {
        [CompletionUpdate(items: items, isFinished: true, advertisement: advertisement, emptyText: emptyText)]
    }

    /// Resolution context at `byteOffset`: package-qualified enclosing types (innermost first)
    /// plus the type parameters of enclosing types and methods.
    static func resolutionContext(in tree: JavaSyntaxTree, fileStubs: JavaSourceFileStubs, atByteOffset byteOffset: Int) -> JavaResolutionContext {
        let enclosing = enclosingTypeContext(in: tree, atByteOffset: byteOffset)
        let qualified = enclosing.qualifiedNames.map { name in
            fileStubs.packageName.isEmpty ? name : "\(fileStubs.packageName).\(name)"
        }
        return JavaResolutionContext(
            packageName: fileStubs.packageName,
            imports: fileStubs.imports,
            enclosingTypeQualifiedNames: qualified,
            typeParameterNames: enclosing.typeParameterNames.union(methodTypeParameters(in: tree, atByteOffset: byteOffset)),
            typeParameterBounds: typeParameterBounds(in: tree, atByteOffset: byteOffset)
        )
    }

    /// First bounds of the type parameters of every enclosing type and method, innermost winning.
    static func typeParameterBounds(in tree: JavaSyntaxTree, atByteOffset byteOffset: Int) -> [String: JavaTypeRef] {
        let declarations: Set<String> = [
            "class_declaration", "interface_declaration", "record_declaration", "method_declaration", "constructor_declaration"
        ]
        var bounds: [String: JavaTypeRef] = [:]
        var shadowed = Set<String>()
        var current: SyntaxNode? = tree.node(atByteOffset: byteOffset)
        while let node = current {
            if declarations.contains(node.type), let parameters = node.child(byFieldName: "type_parameters") {
                for parameter in parameters.namedChildren(ofType: "type_parameter") {
                    guard let name = parameter.namedChildren.first(where: { $0.type == "type_identifier" || $0.type == "identifier" })?.text,
                          shadowed.insert(name).inserted else { continue }
                    if let bound = parameter.firstNamedChild(ofType: "type_bound"), let first = bound.namedChildren.first {
                        bounds[name] = JavaTypeNodeConverter.convert(first)
                    }
                }
            }
            current = node.parent
        }
        return bounds
    }

    // MARK: - Member access

    private func memberAccessItems(dotOffset: Int, source: String, request: Request) async -> [CompletionItem] {
        guard let receiver = await JavaExpressionTyper.receiverInfo(
            source: source, realTree: request.tree, dotOffset: dotOffset, context: request.context, index: index
        ) else {
            javaCompletionLog.debug("java receiver could not be typed")
            return []
        }
        javaCompletionLog.debug("java receiver=\(String(describing: receiver.type), privacy: .public) static=\(receiver.isTypeReference)")
        if let packageName = receiver.packageName {
            return await packageMemberItems(packageName: packageName, request: request)
        }
        let expected = await JavaExpectedType.infer(at: Self.expressionStart(beforeDot: dotOffset, bytes: request.bytes, source: source), request: request.semantic)
        let assignability = JavaAssignability(index: index, context: request.context)
        let mode: JavaMemberLookupMode = receiver.isTypeReference ? .staticOnly : .instance
        let members = await JavaMemberLookup.members(of: receiver.type, mode: mode, context: request.context, index: index)
        let receiverName = receiver.type.erasedQualifiedName
        var items: [CompletionItem] = []
        items.reserveCapacity(members.count + 4)
        let assignedName = JavaExpectedType.assignedName(
            at: Self.expressionStart(beforeDot: dotOffset, bytes: request.bytes, source: source), bytes: request.bytes
        )
        for member in members {
            let matches = await Self.matchesExpected(member.valueType, expected: expected, assignability: assignability)
            items.append(request.factory.memberItem(
                member, receiverQualifiedName: receiverName ?? "<array>", expectedMatch: matches,
                priorityAdjustment: Self.memberAdjustment(member: member, expected: expected, assignedName: assignedName)
                    // Legal but unidiomatic: a static member reached through an instance.
                    - (!receiver.isTypeReference && member.modifiers.contains(.staticFlag) ? 1 : 0)
            ))
        }
        if !receiver.isTypeReference, !request.prefix.isEmpty,
           let expression = JavaExpressionTyper.treeReceiverRange(in: request.tree, dotOffset: dotOffset)
               ?? JavaReceiverScanner.receiverRange(in: request.bytes, dotOffset: dotOffset) {
            let element = await JavaExpressionTyper.iteratedElementType(of: receiver.type, context: request.context, index: index)
            let postfix = JavaPostfixTemplates(
                text: request.text, bytes: request.bytes, expression: expression, dotOffset: dotOffset,
                factory: request.factory, source: name,
                takenNames: Set(JavaLocalScope.locals(in: request.tree, atByteOffset: request.cursor).map(\.name))
            )
            items += postfix.items(receiverType: receiver.type, elementType: element, isIterable: element != nil)
        }
        if receiver.isTypeReference, let receiverName, let stub = await index.classStub(qualifiedName: receiverName) {
            for inner in stub.innerTypeNames {
                if let innerStub = await index.classStub(qualifiedName: inner) {
                    items.append(request.factory.classItem(innerStub, importDecision: .none, priority: JavaCompletionPriority.ownMember))
                }
            }
            items.append(request.factory.keywordItem("class", priority: JavaCompletionPriority.inheritedMember))
            if request.context.enclosingTypeQualifiedNames.dropFirst().contains(receiverName) {
                items.append(request.factory.keywordItem("this", priority: JavaCompletionPriority.inheritedMember))
            }
        }
        return items
    }

    /// Where the expression that ends with `receiver.` starts, for expected-type inference
    /// (`String s = foo.|` expects a `String` from the member).
    private static func expressionStart(beforeDot dotOffset: Int, bytes: [UInt8], source: String) -> Int {
        JavaReceiverScanner.receiverRange(in: bytes, dotOffset: dotOffset)?.lowerBound ?? dotOffset
    }

    private func packageMemberItems(packageName: String, request: Request) async -> [CompletionItem] {
        var items = await index.subpackages(of: packageName).map { request.factory.packageItem($0) }
        for stub in await index.classes(inPackage: packageName) where stub.outerQualifiedName == nil {
            items.append(request.factory.classItem(stub, importDecision: .none, priority: JavaCompletionPriority.classInScope))
        }
        return items
    }

    private func methodReferenceItems(colonOffset: Int, request: Request) async -> [CompletionItem] {
        // Reuse the `.` receiver scanner: `Foo::` reads like `Foo .`.
        var bytes = request.bytes
        bytes[colonOffset] = UInt8(ascii: " ")
        bytes[colonOffset + 1] = UInt8(ascii: ".")
        let source = String(decoding: bytes, as: UTF8.self)
        guard let receiver = await JavaExpressionTyper.receiverInfo(
            source: source, realTree: request.tree, dotOffset: colonOffset + 1, context: request.context, index: index
        ), receiver.packageName == nil else { return [] }
        // `Type::instanceMethod` is legal (the receiver becomes the first argument), so a type
        // reference offers instance methods too.
        let members = await JavaMemberLookup.members(of: receiver.type, mode: .instance, context: request.context, index: index)
        var seen = Set<String>()
        var items: [CompletionItem] = []
        for member in members {
            guard case .method = member, seen.insert(member.name).inserted else { continue }
            items.append(request.factory.memberItem(member, receiverQualifiedName: receiver.type.erasedQualifiedName, asMethodReference: true))
        }
        if receiver.isTypeReference {
            items.append(request.factory.keywordItem("new", priority: JavaCompletionPriority.ownMember))
        }
        return items
    }

    // MARK: - Imports

    private func importItems(qualifier: String, isStatic: Bool, request: Request) async -> [CompletionItem] {
        var items = await index.subpackages(of: qualifier).map { request.factory.packageItem($0) }
        if qualifier.isEmpty { return items }
        if let owner = await index.classStub(qualifiedName: qualifier) {
            // `import java.util.Map.|` / `import static java.lang.Math.|`
            for inner in owner.innerTypeNames {
                if let innerStub = await index.classStub(qualifiedName: inner) {
                    items.append(request.factory.classItem(innerStub, importDecision: .none, priority: JavaCompletionPriority.classInScope))
                }
            }
            if isStatic {
                let members = await JavaMemberLookup.members(
                    of: .classType(qualifiedName: qualifier, arguments: [], outer: nil), mode: .staticOnly, context: request.context, index: index
                )
                var seen = Set<String>()
                for member in members where seen.insert(member.name).inserted {
                    items.append(CompletionItem(
                        label: member.name, insertText: member.name,
                        kind: { if case .field = member { return .field } else { return .method } }(),
                        range: request.factory.range, source: name, detail: member.declaringClass,
                        priority: JavaCompletionPriority.ownMember
                    ))
                }
                items.append(request.factory.keywordItem("*"))
            }
            return items
        }
        for stub in await index.classes(inPackage: qualifier) where stub.outerQualifiedName == nil {
            items.append(request.factory.classItem(stub, importDecision: .none, priority: JavaCompletionPriority.classInScope))
        }
        items.append(request.factory.keywordItem("*"))
        return items
    }

    // MARK: - Annotations

    private static let commonAnnotations = [
        "java.lang.Override", "java.lang.Deprecated", "java.lang.SuppressWarnings",
        "java.lang.FunctionalInterface", "java.lang.SafeVarargs"
    ]

    private func annotationItems(request: Request) async -> [CompletionItem] {
        var items: [CompletionItem] = []
        if request.prefix.isEmpty {
            var names = Self.commonAnnotations
            names += request.fileStubs.imports.filter { !$0.isStatic && !$0.isOnDemand }.map(\.qualifiedName)
            for name in names {
                guard let stub = await index.classStub(qualifiedName: name), stub.kind == .annotationKind else { continue }
                items.append(request.factory.classItem(stub, importDecision: request.importer.decision(for: stub), priority: JavaCompletionPriority.classInScope))
            }
            return items
        }
        for match in await index.classes(matching: request.prefix, limit: 400) where match.stub.kind == .annotationKind {
            let decision = request.importer.decision(for: match.stub)
            items.append(request.factory.classItem(match.stub, importDecision: decision, priority: classPriority(match.stub, decision: decision, request: request)))
        }
        return items
    }

    private func annotationAttributeItems(annotationName: String, request: Request) async -> [CompletionItem] {
        let type = await JavaTypeResolver.resolve(
            annotationName.contains(".") ? .classType(qualifiedName: annotationName, arguments: [], outer: nil) : .unresolved(simpleName: annotationName, arguments: []),
            context: request.context, index: index
        )
        guard let qualifiedName = type.erasedQualifiedName, let stub = await index.classStub(qualifiedName: qualifiedName) else { return [] }
        return stub.methods.filter { !$0.isConstructor && !$0.modifiers.contains(.staticFlag) }.map { method in
            CompletionItem(
                label: method.name, insertText: "\(method.name) = ", kind: .property, range: request.factory.range, source: name,
                documentation: method.javadoc, detail: JavaCompletionItemFactory.display(method.returnType),
                priority: JavaCompletionPriority.ownMember
            )
        }
    }

    // MARK: - new

    private func newExpressionUpdates(request: Request) async -> [CompletionUpdate] {
        let expected = await JavaExpectedType.infer(at: Self.newKeywordStart(before: request.prefixStart, bytes: request.bytes), request: request.semantic)
        let assignability = JavaAssignability(index: index, context: request.context)
        var fastStubs: [JavaClassStub] = []
        var seen = Set<String>()
        func add(_ stub: JavaClassStub?) {
            guard let stub, stub.kind != .enumKind, stub.kind != .annotationKind, seen.insert(stub.qualifiedName).inserted else { return }
            fastStubs.append(stub)
        }
        for type in expected {
            if let name = type.erasedQualifiedName {
                add(await index.classStub(qualifiedName: name))
                if let standIn = JavaCompletionSuggestions.jdkImplementations[name] {
                    add(await index.classStub(qualifiedName: standIn))
                }
            }
        }
        if request.prefix.isEmpty {
            for stub in await index.classes(inPackage: request.context.packageName) {
                let classType = JavaTypeRef.classType(qualifiedName: stub.qualifiedName, arguments: [], outer: nil)
                if await Self.matchesExpected(classType, expected: expected, assignability: assignability) {
                    add(stub)
                }
            }
        } else {
            for stub in await inScopeClassStubs(request: request) {
                let classType = JavaTypeRef.classType(qualifiedName: stub.qualifiedName, arguments: [], outer: nil)
                if await Self.matchesExpected(classType, expected: expected, assignability: assignability) {
                    add(stub)
                }
            }
        }
        let fast = await constructorItems(fastStubs, expected: expected, assignability: assignability, request: request)
        var slowStubs = await extraNewStubs(request: request, expected: expected, assignability: assignability, excluding: seen)
        if request.prefix.isEmpty {
            slowStubs += await implementationStubs(request: request, expected: expected, assignability: assignability, excluding: seen)
        }
        let slow = await constructorItems(slowStubs, expected: expected, assignability: assignability, request: request)
        return phased(fast: fast, slow: slow, request: request, expected: expected, offersClasses: false)
    }

    private func constructorItems(
        _ stubs: [JavaClassStub], expected: [JavaTypeRef], assignability: JavaAssignability, request: Request
    ) async -> [CompletionItem] {
        var items: [CompletionItem] = []
        for stub in stubs where stub.kind != .enumKind && stub.kind != .annotationKind {
            let decision = request.importer.decision(for: stub)
            let classType = JavaTypeRef.classType(qualifiedName: stub.qualifiedName, arguments: [], outer: nil)
            let decisionForNew = await Self.newTypeDecision(classType, expected: expected, assignability: assignability)
            guard decisionForNew.keep else { continue }
            // Preferred implementation: the conventional class for an expected JDK interface
            // (`ArrayList` for `List`) leads the other implementations (`Stack`, `Vector`).
            let preferred = expected.contains { $0.erasedQualifiedName.flatMap { JavaCompletionSuggestions.jdkImplementations[$0] } == stub.qualifiedName }
            items.append(request.factory.constructorItem(
                stub, importDecision: decision,
                priority: classPriority(stub, decision: decision, request: request) + (preferred ? JavaCompletionPriority.affinityStep * 4 : 0),
                expectedMatch: decisionForNew.matches, anonymous: JavaCompletionSuggestions.isAnonymous(stub)
            ))
        }
        return items
    }

    /// `List<User> x = new |` with nothing typed: concrete classes assignable to the expected type
    /// from the packages the code is likely to use -- the expected type's own package, this
    /// file's package, its imports, and `java.lang` (`ArrayList`, `LinkedList`, … for `List`).
    /// There is no inheritor index, so types elsewhere on the classpath need a typed prefix.
    private func implementationStubs(
        request: Request, expected: [JavaTypeRef], assignability: JavaAssignability, excluding: Set<String>
    ) async -> [JavaClassStub] {
        let targets = expected.compactMap(\.erasedQualifiedName).filter { $0 != "java.lang.Object" }
        guard !targets.isEmpty else { return [] }
        var packages: [String] = [request.context.packageName, "java.lang"]
        for target in targets {
            if let stub = await index.classStub(qualifiedName: target) { packages.append(stub.packageName) }
        }
        for declaration in request.context.imports where !declaration.isStatic {
            if declaration.isOnDemand {
                packages.append(declaration.qualifiedName)
            } else if let stub = await index.classStub(qualifiedName: declaration.qualifiedName) {
                packages.append(stub.packageName)
            }
        }
        var seenPackages = Set<String>()
        var seen = excluding
        var stubs: [JavaClassStub] = []
        for package in packages where seenPackages.insert(package).inserted {
            for stub in await index.classes(inPackage: package) {
                guard stub.kind == .classKind || stub.kind == .recordKind, !stub.modifiers.contains(.abstractFlag),
                      stub.outerQualifiedName == nil, !stub.qualifiedName.hasPrefix("com.sun."),
                      isAccessibleClass(stub, request: request), !seen.contains(stub.qualifiedName) else { continue }
                let classType = JavaTypeRef.classType(qualifiedName: stub.qualifiedName, arguments: [], outer: nil)
                guard await Self.matchesExpected(classType, expected: expected, assignability: assignability) else { continue }
                seen.insert(stub.qualifiedName)
                stubs.append(stub)
            }
        }
        return stubs
    }

    /// Prefix search for `new`, kept to types assignable to the expected type.
    private func extraNewStubs(
        request: Request, expected: [JavaTypeRef], assignability: JavaAssignability, excluding: Set<String>
    ) async -> [JavaClassStub] {
        guard !request.prefix.isEmpty else { return [] }
        var stubs: [JavaClassStub] = []
        for match in await index.classes(matching: request.prefix, limit: classNameLimit(request)) {
            let stub = match.stub
            guard !excluding.contains(stub.qualifiedName), stub.kind != .enumKind, stub.kind != .annotationKind,
                  isAccessibleClass(stub, request: request) else { continue }
            let classType = JavaTypeRef.classType(qualifiedName: stub.qualifiedName, arguments: [], outer: nil)
            let decisionForNew = await Self.newTypeDecision(classType, expected: expected, assignability: assignability)
            guard decisionForNew.keep else { continue }
            stubs.append(stub)
        }
        return stubs
    }

    private static func newKeywordStart(before prefixStart: Int, bytes: [UInt8]) -> Int {
        let end = JavaCompletionContextClassifier.skipWhitespace(backwardFrom: prefixStart, in: bytes)
        return max(0, end - 3)
    }

    // MARK: - Type-only positions

    private func typeOnlyUpdates(keyword: String, request: Request) async -> [CompletionUpdate] {
        let inScope = await inScopeClassStubs(request: request)
        let fast = await typeOnlyItems(keyword: keyword, request: request, stubs: inScope)
        let extra = await extraClassStubs(request: request, existing: fast)
        let slow = await typeOnlyClassItems(keyword: keyword, request: request, stubs: extra)
        return phased(fast: fast, slow: slow, request: request, expected: [], offersClasses: true)
    }

    private func typeOnlyItems(keyword: String, request: Request, stubs: [JavaClassStub]) async -> [CompletionItem] {
        var items: [CompletionItem] = []
        for typeParameter in request.context.typeParameterNames.sorted() {
            items.append(CompletionItem(
                label: typeParameter, insertText: typeParameter, kind: .type, range: request.factory.range, source: name,
                priority: JavaCompletionPriority.local
            ))
        }
        guard !request.prefix.isEmpty else { return items }
        items += await typeOnlyClassItems(keyword: keyword, request: request, stubs: stubs)
        return items
    }

    private func typeOnlyClassItems(keyword: String, request: Request, stubs: [JavaClassStub]) async -> [CompletionItem] {
        var items: [CompletionItem] = []
        for stub in stubs {
            switch keyword {
            case "implements":
                guard stub.kind == .interfaceKind else { continue }
            case "extends":
                guard stub.kind == .classKind || stub.kind == .interfaceKind, !stub.modifiers.contains(.finalFlag) else { continue }
            default:
                break
            }
            let decision = request.importer.decision(for: stub)
            var priority = classPriority(stub, decision: decision, request: request)
            if keyword == "catch" || keyword == "throws", stub.simpleName.hasSuffix("Exception") || stub.simpleName.hasSuffix("Error") {
                priority += 1
            }
            items.append(request.factory.classItem(stub, importDecision: decision, priority: priority))
        }
        return items
    }

    // MARK: - case

    private func caseLabelItems(selectorText: String, request: Request) async -> [CompletionItem] {
        let locals = await JavaExpressionTyper.resolvingVarLocals(
            JavaLocalScope.locals(in: request.tree, atByteOffset: request.prefixStart), context: request.context, index: index
        )
        guard let selector = await JavaExpressionTyper.typeOfExpression(selectorText, locals: locals, context: request.context, index: index),
              let name = selector.type.erasedQualifiedName,
              let stub = await index.classStub(qualifiedName: name), stub.kind == .enumKind else { return [] }
        return stub.fields.filter { $0.modifiers.contains(.enumConstant) }.map { field in
            CompletionItem(
                label: field.name, insertText: field.name, kind: .enumMember, range: request.factory.range, source: self.name,
                detail: stub.simpleName, priority: JavaCompletionPriority.ownMember
            )
        }
    }

    // MARK: - Class body

    private static let memberModifierKeywords = [
        "public", "private", "protected", "static", "final", "abstract", "synchronized", "native",
        "transient", "volatile", "default", "class", "interface", "enum", "record", "void",
        "boolean", "byte", "char", "short", "int", "long", "float", "double"
    ]

    private func classBodyUpdates(request: Request) async -> [CompletionUpdate] {
        let base = await classBodyItems(request: request, classes: [])
        let inScope = await inScopeClassNameItems(request: request)
        let extra = await extraClassNameItems(request: request, existing: base + inScope)
        return phased(fast: base + inScope, slow: extra, request: request, expected: [], offersClasses: true)
    }

    private func classBodyItems(request: Request, classes: [CompletionItem]) async -> [CompletionItem] {
        var items = Self.memberModifierKeywords.map { request.factory.keywordItem($0) }
        items += classes
        for typeParameter in request.context.typeParameterNames.sorted() {
            items.append(CompletionItem(label: typeParameter, insertText: typeParameter, kind: .type, range: request.factory.range, source: name, priority: JavaCompletionPriority.local))
        }
        items += await overrideItems(request: request)
        return items
    }

    /// `@Override` stubs for methods inherited from supertypes that this class doesn't declare yet.
    private func overrideItems(request: Request) async -> [CompletionItem] {
        guard !request.prefix.isEmpty || request.isManual,
              let selfName = request.context.enclosingTypeQualifiedNames.first else { return [] }
        let selfType = JavaTypeRef.classType(qualifiedName: selfName, arguments: [], outer: nil)
        let members = await JavaMemberLookup.members(of: selfType, mode: .instance, context: request.context, index: index)
        let indentation = Self.lineIndentation(before: request.prefixStart, bytes: request.bytes)
        var items: [CompletionItem] = []
        var unimplemented: [CompletionItem] = []
        for member in members {
            guard case .method(let method, let declaringClass) = member, declaringClass != selfName else { continue }
            let modifiers = method.modifiers
            guard !modifiers.contains(.finalFlag), !modifiers.contains(.staticFlag), !modifiers.contains(.privateFlag) else { continue }
            let declaringKind = await index.classStub(qualifiedName: declaringClass)?.kind
            let item = request.factory.overrideItem(
                method, declaringClass: declaringClass, isInterfaceMethod: declaringKind == .interfaceKind, indentation: indentation
            )
            items.append(item)
            // Members come most-derived first with overrides folded in, so an abstract method
            // still listed here has no implementation anywhere between it and this class.
            let isAbstract = modifiers.contains(.abstractFlag) || (declaringKind == .interfaceKind && !modifiers.contains(.defaultMethod))
            if isAbstract { unimplemented.append(item) }
        }
        let selfKind = request.fileStubs.classes.first { $0.qualifiedName == selfName }?.kind
        let selfIsConcrete = (selfKind == .classKind || selfKind == .enumKind || selfKind == .recordKind)
            && request.fileStubs.classes.first { $0.qualifiedName == selfName }?.modifiers.contains(.abstractFlag) == false
        if selfIsConcrete, unimplemented.count >= 2 {
            items.append(implementAllItem(unimplemented, indentation: indentation, factory: request.factory))
        }
        return items
    }

    /// One item that inserts every missing abstract method, caret in the first body.
    private func implementAllItem(_ stubs: [CompletionItem], indentation: String, factory: JavaCompletionItemFactory) -> CompletionItem {
        let bodies = stubs.enumerated().map { position, item in
            position == 0 ? item.insertText : item.insertText.replacingOccurrences(of: "$0", with: "")
        }
        return CompletionItem(
            label: "implement methods", insertText: bodies.joined(separator: "\n\n\(indentation)"), kind: .snippet,
            range: factory.range, source: name, filterText: "implement",
            detail: "\(stubs.count) abstract methods", labelDetail: " (\(stubs.map(\.label).joined(separator: ", ")))",
            insertTextIsSnippet: true, priority: JavaCompletionPriority.ownMember
        )
    }

    private static func lineIndentation(before offset: Int, bytes: [UInt8]) -> String {
        var lineStart = min(offset, bytes.count)
        while lineStart > 0, bytes[lineStart - 1] != 10 {
            lineStart -= 1
        }
        var end = lineStart
        while end < bytes.count, bytes[end] == 32 || bytes[end] == 9 {
            end += 1
        }
        return String(decoding: bytes[lineStart..<end], as: UTF8.self)
    }

    // MARK: - Statement position

    private static let statementKeywords = [
        "if", "else", "for", "while", "do", "switch", "break", "continue", "return", "throw", "try",
        "catch", "finally", "new", "this", "super", "null", "true", "false", "var", "final",
        "instanceof", "assert", "synchronized", "yield", "case", "default",
        "boolean", "byte", "char", "short", "int", "long", "float", "double"
    ]

    private static let topLevelKeywords = [
        "package", "import", "public", "final", "abstract", "sealed", "class", "interface", "enum", "record"
    ]

    private func statementUpdates(request: Request) async -> [CompletionUpdate] {
        let draft = await statementDraft(request: request)
        let extras = await statementExtras(request: request, draft: draft)
        return phased(fast: draft.items, slow: extras, request: request, expected: draft.expected, offersClasses: draft.expected.isEmpty)
    }

    private struct StatementDraft {
        var items: [CompletionItem]
        var expected: [JavaTypeRef]
        var locals: [JavaLocalVariable]
        var members: [JavaResolvedMember]
    }

    private func statementItems(request: Request) async -> [CompletionItem] {
        await statementDraft(request: request).items
    }

    private func statementDraft(request: Request) async -> StatementDraft {
        let rawLocals = JavaLocalScope.locals(in: request.tree, atByteOffset: request.cursor)
        let locals = await JavaExpressionTyper.resolvingVarLocals(rawLocals, context: request.context, index: index)
        let semantic = JavaSemanticRequest(source: request.text, bytes: request.bytes, tree: request.tree, locals: locals, context: request.context, index: index)
        let expected = await JavaExpectedType.infer(at: request.prefixStart, request: semantic)
        let assignedName = JavaExpectedType.assignedName(at: request.prefixStart, bytes: request.bytes)
        let assignability = JavaAssignability(index: index, context: request.context)
        var items: [CompletionItem] = []
        var members: [JavaResolvedMember] = []

        for local in locals {
            let matches = await Self.matchesExpected(local.type, expected: expected, assignability: assignability)
            items.append(request.factory.localItem(local, expectedMatch: matches))
        }

        let isStatic = Self.isStaticContext(tree: request.tree, offset: request.cursor)
        // Access rules apply on the first invocation only: a second Ctrl+Space also offers members
        // the code can't legally reach (an inherited `private` field, a package-private member
        // from another package), like IntelliJ's second basic completion. Member access after a
        // `.` always checks access. Corpus: `ScopeInheritedPrivate*`, `VisibilityPackageClass*`.
        var seenMembers = Set<String>()
        for (depth, enclosing) in request.context.enclosingTypeQualifiedNames.enumerated() {
            let selfType = JavaTypeRef.classType(qualifiedName: enclosing, arguments: [], outer: nil)
            let mode: JavaMemberLookupMode = isStatic ? .staticOnly : .instance
            let visible = await JavaMemberLookup.members(
                of: selfType, mode: mode, context: request.context, index: index, checkAccess: request.invocationCount <= 1
            )
            if depth == 0 { members = visible }
            for member in visible {
                let key = Self.memberKey(member)
                guard seenMembers.insert(key).inserted else { continue }
                let matches = await Self.matchesExpected(member.valueType, expected: expected, assignability: assignability)
                let base: Double? = depth == 0 ? nil : JavaCompletionPriority.outerMember
                items.append(request.factory.memberItem(
                    member, receiverQualifiedName: enclosing, basePriority: base, expectedMatch: matches,
                    priorityAdjustment: Self.memberAdjustment(member: member, expected: expected, assignedName: assignedName)
                ))
            }
        }
        for member in await JavaStaticImports.members(context: request.context, index: index) {
            guard seenMembers.insert(Self.memberKey(member)).inserted else { continue }
            let matches = await Self.matchesExpected(member.valueType, expected: expected, assignability: assignability)
            items.append(request.factory.memberItem(member, receiverQualifiedName: nil, basePriority: JavaCompletionPriority.staticImport, expectedMatch: matches))
        }

        items += await inScopeClassNameItems(request: request)

        if !request.prefix.isEmpty || request.isManual {
            let expectsBoolean = expected.contains(.primitive(.boolean)) || expected.contains { $0.erasedQualifiedName == "java.lang.Boolean" }
            let allowed = JavaKeywordPosition(tree: request.tree, bytes: request.bytes, offset: request.prefixStart, isStatic: isStatic)
            for keyword in Self.statementKeywords where allowed.permits(keyword) {
                var priority = JavaCompletionPriority.keyword
                if expectsBoolean, keyword == "true" || keyword == "false" { priority += JavaCompletionPriority.expectedTypeBonus }
                if !expected.isEmpty, keyword == "new" || keyword == "null" { priority += 1 }
                items.append(request.factory.keywordItem(keyword, priority: priority))
            }
        }
        return StatementDraft(items: items, expected: expected, locals: locals, members: members)
    }

    private func statementExtras(request: Request, draft: StatementDraft) async -> [CompletionItem] {
        let assignability = JavaAssignability(index: index, context: request.context)
        var items = await extraClassNameItems(request: request, existing: draft.items)
        let fastMatched = draft.items.contains(where: \.preselect)
        items += await JavaCompletionSuggestions.chains(
            locals: draft.locals, members: draft.members, expected: draft.expected,
            invocationCount: request.invocationCount, mode: request.mode, fastHasExpectedMatch: fastMatched,
            factory: request.factory, context: request.context, index: index, assignability: assignability
        )
        items += JavaCompletionSuggestions.toArrayConversions(locals: draft.locals, expected: draft.expected, factory: request.factory)
        items += JavaCompletionSuggestions.collectionFactories(
            expected: draft.expected, prefix: request.prefix, imports: request.context.imports, factory: request.factory, importer: request.importer
        )
        items += await JavaCompletionSuggestions.functionalTemplates(
            expected: draft.expected, members: draft.members, factory: request.factory, context: request.context, index: index
        )
        return items
    }

    /// Classes matching the typed prefix (none for an empty prefix -- like IntelliJ, class names
    /// only come in once something is typed), auto-imported on accept.
    private func classNameItems(request: Request) async -> [CompletionItem] {
        guard !request.prefix.isEmpty else { return [] }
        var items: [CompletionItem] = []
        let ownNames = Set(request.context.enclosingTypeQualifiedNames)
        for match in await index.classes(matching: request.prefix, limit: classNameLimit(request)) where isAccessibleClass(match.stub, request: request) {
            let decision = ownNames.contains(match.stub.qualifiedName) ? .none : request.importer.decision(for: match.stub)
            items.append(request.factory.classItem(match.stub, importDecision: decision, priority: classPriority(match.stub, decision: decision, request: request)))
        }
        return items
    }

    private func classNameLimit(_ request: Request) -> Int {
        request.invocationCount >= 2 ? classNameCompletionLimit * 4 : classNameCompletionLimit
    }

    private func inScopeClassNameItems(request: Request) async -> [CompletionItem] {
        classItems(stubs: await inScopeClassStubs(request: request), request: request)
    }

    private func extraClassNameItems(request: Request, existing: [CompletionItem]) async -> [CompletionItem] {
        classItems(stubs: await extraClassStubs(request: request, existing: existing), request: request)
    }

    private func classItems(stubs: [JavaClassStub], request: Request) -> [CompletionItem] {
        let ownNames = Set(request.context.enclosingTypeQualifiedNames)
        return stubs.map { stub in
            let decision = ownNames.contains(stub.qualifiedName) ? JavaImportInserter.Decision.none : request.importer.decision(for: stub)
            return request.factory.classItem(stub, importDecision: decision, priority: classPriority(stub, decision: decision, request: request))
        }
    }

    /// Same package, `java.lang`, explicit and on-demand imports, and types declared in this file.
    private func inScopeClassStubs(request: Request) async -> [JavaClassStub] {
        guard !request.prefix.isEmpty else { return [] }
        var seen = Set<String>()
        var stubs: [JavaClassStub] = []
        func consider(_ stub: JavaClassStub) {
            guard JavaCompletionSuggestions.prefixMatches(request.prefix, stub.simpleName), isAccessibleClass(stub, request: request) else { return }
            guard seen.insert(stub.qualifiedName).inserted else { return }
            if case .none = request.importer.decision(for: stub) {
                stubs.append(stub)
            }
        }
        for stub in await index.classes(inPackage: request.context.packageName) { consider(stub) }
        if request.context.packageName != "java.lang" {
            for stub in await index.classes(inPackage: "java.lang") { consider(stub) }
        }
        for declaration in request.context.imports where !declaration.isStatic {
            if declaration.isOnDemand {
                for stub in await index.classes(inPackage: declaration.qualifiedName) { consider(stub) }
            } else if let stub = await index.classStub(qualifiedName: declaration.qualifiedName) {
                consider(stub)
            }
        }
        for stub in request.fileStubs.classes { consider(stub) }
        return stubs
    }

    /// Classpath classes that clear the better-prefix bar, or every prefix match on a second Ctrl+Space.
    private func extraClassStubs(request: Request, existing: [CompletionItem]) async -> [JavaClassStub] {
        guard !request.prefix.isEmpty else { return [] }
        let best = JavaCompletionSuggestions.bestDegree(prefix: request.prefix, items: existing)
        // Keyed by name and package, so `com.acme.other.List` still comes in next to `java.util.List`.
        let present = Set(existing.map { "\($0.label)|\($0.labelDetail ?? "")" })
        var stubs: [JavaClassStub] = []
        for match in await index.classes(matching: request.prefix, limit: classNameLimit(request)) {
            let stub = match.stub
            guard !present.contains("\(stub.simpleName)|\(JavaCompletionItemFactory.classTail(stub))"),
                  isAccessibleClass(stub, request: request) else { continue }
            guard JavaCompletionSuggestions.admitsExtraClass(
                prefix: request.prefix, simpleName: stub.simpleName, invocationCount: request.invocationCount, best: best
            ) else { continue }
            stubs.append(stub)
        }
        return stubs
    }

    private func annotationUpdates(request: Request) async -> [CompletionUpdate] {
        if request.prefix.isEmpty {
            return finished(await annotationItems(request: request))
        }
        let fast = classItems(
            stubs: await inScopeClassStubs(request: request).filter { $0.kind == .annotationKind }, request: request
        )
        let slow = classItems(
            stubs: await extraClassStubs(request: request, existing: fast).filter { $0.kind == .annotationKind }, request: request
        )
        return phased(fast: fast, slow: slow, request: request, expected: [], offersClasses: true)
    }

    private func castUpdates(request: Request) async -> [CompletionUpdate] {
        let rawLocals = JavaLocalScope.locals(in: request.tree, atByteOffset: request.cursor)
        let locals = await JavaExpressionTyper.resolvingVarLocals(rawLocals, context: request.context, index: index)
        let semantic = JavaSemanticRequest(
            source: request.text, bytes: request.bytes, tree: request.tree, locals: locals, context: request.context, index: index
        )
        let paren = max(0, request.prefixStart - 1)
        let expected = await JavaExpectedType.infer(at: paren, request: semantic)
        let casts = JavaCompletionSuggestions.casts(expected: expected, factory: request.factory)
        guard !request.prefix.isEmpty else {
            return phased(fast: casts, slow: [], request: request, expected: expected, offersClasses: false)
        }
        // `(us|` may be a parenthesized value as well as a cast: offer what a statement would.
        let draft = await statementDraft(request: request)
        let extras = await statementExtras(request: request, draft: draft)
        return phased(fast: casts + draft.items, slow: extras, request: request, expected: expected, offersClasses: true)
    }

    private func phased(
        fast: [CompletionItem], slow: [CompletionItem], request: Request, expected: [JavaTypeRef], offersClasses: Bool
    ) -> [CompletionUpdate] {
        let advertisement = JavaCompletionSuggestions.advertisement(
            mode: request.mode, prefix: request.prefix, invocationCount: request.invocationCount,
            expected: expected, offersClasses: offersClasses
        )
        let emptyText = request.mode == .smart ? JavaCompletionSuggestions.smartEmptyText(expected: expected) : nil
        let first = applyMode(fast, request: request, expected: expected)
        if slow.isEmpty {
            return [CompletionUpdate(items: first, isFinished: true, advertisement: advertisement, emptyText: emptyText)]
        }
        let merged = applyMode(fast + slow, request: request, expected: expected)
        return [
            CompletionUpdate(items: first, isFinished: false, advertisement: advertisement),
            CompletionUpdate(items: merged, isFinished: true, advertisement: advertisement, emptyText: emptyText)
        ]
    }

    private func applyMode(_ items: [CompletionItem], request: Request, expected: [JavaTypeRef]) -> [CompletionItem] {
        guard request.mode == .smart else { return items }
        return JavaCompletionSuggestions.filterSmart(items, expected: expected, prefix: request.prefix)
    }

    /// Sinks void methods in an expression, and lifts a method whose name ends like the assigned variable.
    private static func memberAdjustment(member: JavaResolvedMember, expected: [JavaTypeRef], assignedName: String?) -> Double {
        guard case .method(let method, _) = member else { return 0 }
        var adjustment = 0.0
        if !expected.isEmpty, method.returnType == .void { adjustment -= 2 }
        if let assignedName, method.name.lowercased().hasSuffix(assignedName.lowercased()), method.name.count > assignedName.count {
            adjustment += 0.4
        }
        return adjustment
    }

    /// Whether code in this file may name `stub`: public types anywhere, package-private (and
    /// protected nested) types in the same package, private nested types inside the same
    /// top-level type. A second Ctrl+Space shows them all, like IntelliJ.
    private func isAccessibleClass(_ stub: JavaClassStub, request: Request) -> Bool {
        guard request.invocationCount <= 1, !stub.modifiers.contains(.publicFlag) else { return true }
        if stub.modifiers.contains(.privateFlag) {
            guard let topLevel = request.context.topLevelTypeQualifiedName else { return false }
            return stub.qualifiedName.hasPrefix("\(topLevel).")
        }
        return stub.packageName == request.context.packageName
    }

    /// Package affinity, the class-ranking feature after match tier and expected type: a class
    /// the file names explicitly (same package, single-type import) beats `java.lang`, which beats
    /// an on-demand import; out of scope, `java.*` beats other libraries, which beat JDK internals.
    /// Named steps of 0.25 keep this below the scope buckets in ``JavaCompletionPriority``.
    private func classPriority(_ stub: JavaClassStub, decision: JavaImportInserter.Decision, request: Request) -> Double {
        if case .none = decision {
            let context = request.context
            let owner = stub.outerQualifiedName ?? stub.packageName
            if stub.packageName == context.packageName
                || context.imports.contains(where: { !$0.isStatic && !$0.isOnDemand && $0.qualifiedName == stub.qualifiedName }) {
                return JavaCompletionPriority.classInScope + JavaCompletionPriority.affinityStep * 2
            }
            if owner == "java.lang" {
                return JavaCompletionPriority.classInScope + JavaCompletionPriority.affinityStep
            }
            return JavaCompletionPriority.classInScope
        }
        if stub.packageName.hasPrefix("java.") { return JavaCompletionPriority.classOther + JavaCompletionPriority.affinityStep }
        if stub.packageName.hasPrefix("sun.") || stub.packageName.hasPrefix("com.sun.") || stub.packageName.hasPrefix("jdk.internal") {
            return JavaCompletionPriority.classOther - 1
        }
        return JavaCompletionPriority.classOther
    }

    private static func memberKey(_ member: JavaResolvedMember) -> String {
        switch member {
        case .field(let field, _): return "f:\(field.name)"
        case .method(let method, _): return "m:\(method.name)\(JavaCompletionItemFactory.parameterList(method))"
        }
    }

    /// Keep a `new` candidate when it is assignable, or when the expected type never resolved
    /// (a missing `Object` stub must not hide every constructor).
    static func newTypeDecision(
        _ type: JavaTypeRef, expected: [JavaTypeRef], assignability: JavaAssignability
    ) async -> (keep: Bool, matches: Bool) {
        guard !expected.isEmpty else { return (true, false) }
        let matches = await matchesExpected(type, expected: expected, assignability: assignability)
        if matches { return (true, true) }
        let canFilter = expected.contains {
            switch $0 {
            case .classType, .primitive, .array: return true
            default: return false
            }
        }
        return (keep: !canFilter, matches: false)
    }

    static func matchesExpected(_ type: JavaTypeRef?, expected: [JavaTypeRef], assignability: JavaAssignability) async -> Bool {
        guard let type, !expected.isEmpty, type != .void else { return false }
        let resolved = await assignability.resolve(type)
        for candidate in expected where await assignability.isAssignable(resolved, to: candidate) {
            return true
        }
        return false
    }

    /// Inside a `static` method or initializer of the innermost type, only static members of
    /// that type are reachable without a receiver.
    static func isStaticContext(tree: JavaSyntaxTree, offset: Int) -> Bool {
        var current: SyntaxNode? = tree.node(atByteOffset: offset)
        while let node = current {
            switch node.type {
            case "static_initializer":
                return true
            case "method_declaration":
                return node.firstNamedChild(ofType: "modifiers")?.children.contains { $0.type == "static" } == true
            case "class_body", "constructor_declaration":
                return false
            default:
                current = node.parent
            }
        }
        return false
    }

    // MARK: - Enclosing type / offset helpers

    struct EnclosingTypeContext {
        let qualifiedNames: [String]
        let typeParameterNames: Set<String>
    }

    /// Walks up from the node at `byteOffset` collecting enclosing type declarations (innermost
    /// first) by node type. The names are *not* package-qualified; use
    /// ``resolutionContext(in:fileStubs:atByteOffset:)`` for a ready-to-use context. Best-effort,
    /// like `JavaLocalScope`: a trailing bare `.` on anything beyond a simple identifier can
    /// collapse the whole declaration into one `ERROR` node with no recoverable class name (see
    /// `JavaReceiverScanner`'s doc comment), in which case this simply returns empty for that one
    /// request -- self-correcting on the next keystroke once the tree is well-formed again.
    static func enclosingTypeContext(in tree: JavaSyntaxTree, atByteOffset byteOffset: Int) -> EnclosingTypeContext {
        let typeDeclarationTypes: Set<String> = [
            "class_declaration", "interface_declaration", "enum_declaration", "record_declaration", "annotation_type_declaration"
        ]
        var simpleNames: [String] = [] // innermost first
        var typeParameterNames: Set<String> = []
        var current: SyntaxNode? = tree.node(atByteOffset: byteOffset)
        while let node = current {
            if typeDeclarationTypes.contains(node.type), let nameNode = node.child(byFieldName: "name") {
                simpleNames.append(nameNode.text)
                if let typeParams = node.child(byFieldName: "type_parameters") {
                    for parameter in typeParams.namedChildren(ofType: "type_parameter") {
                        if let paramName = parameter.namedChild(at: 0) {
                            typeParameterNames.insert(paramName.text)
                        }
                    }
                }
            }
            current = node.parent
        }
        guard !simpleNames.isEmpty else { return EnclosingTypeContext(qualifiedNames: [], typeParameterNames: []) }
        // simpleNames is innermost-first; build qualified names by joining from outermost inward.
        var qualifiedNames: [String] = []
        var prefix = ""
        for simpleName in simpleNames.reversed() {
            prefix = prefix.isEmpty ? simpleName : "\(prefix).\(simpleName)"
            qualifiedNames.append(prefix)
        }
        qualifiedNames.reverse() // innermost first, matching JavaResolutionContext's convention
        return EnclosingTypeContext(qualifiedNames: qualifiedNames, typeParameterNames: typeParameterNames)
    }

    /// Type parameters declared by enclosing methods/constructors (`<T> T first(List<T> l)`).
    static func methodTypeParameters(in tree: JavaSyntaxTree, atByteOffset byteOffset: Int) -> Set<String> {
        var names = Set<String>()
        var current: SyntaxNode? = tree.node(atByteOffset: byteOffset)
        while let node = current {
            if node.type == "method_declaration" || node.type == "constructor_declaration",
               let parameters = node.child(byFieldName: "type_parameters") {
                for parameter in parameters.namedChildren(ofType: "type_parameter") {
                    if let name = parameter.child(byFieldName: "name") ?? parameter.namedChild(at: 0) {
                        names.insert(name.text)
                    }
                }
            }
            current = node.parent
        }
        return names
    }

    /// `Document.cursor`/`range` positions are UTF-16 offsets (matching how the rest of Penumbra/
    /// EIP addresses text); everything in `JavaIntelligence` works in UTF-8 byte offsets (matching
    /// tree-sitter). This converts between the two for one position.
    static func utf8ByteOffset(forUTF16Offset utf16Offset: Int, in text: String) -> Int {
        guard let utf16Index = text.utf16.index(text.utf16.startIndex, offsetBy: utf16Offset, limitedBy: text.utf16.endIndex),
              let stringIndex = utf16Index.samePosition(in: text) else {
            return text.utf8.count
        }
        return text.utf8.distance(from: text.utf8.startIndex, to: stringIndex.samePosition(in: text.utf8)!)
    }

    /// Kept for callers that list Java keywords; completion now offers them by context.
    static let keywords: [String] = [
        "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "continue",
        "default", "do", "double", "else", "enum", "extends", "final", "finally", "float", "for",
        "if", "implements", "import", "instanceof", "int", "interface", "long", "new", "null",
        "package", "private", "protected", "public", "return", "short", "static", "super", "switch",
        "synchronized", "this", "throw", "throws", "true", "false", "try", "void", "volatile", "while"
    ]
}

extension JavaResolvedMember {
    /// The type an access to this member produces: a field's type, a method's return type.
    var valueType: JavaTypeRef {
        switch self {
        case .field(let field, _): return field.type
        case .method(let method, _): return method.returnType
        }
    }
}

/// Which statement keywords make sense at the caret, from the tree around the dummy identifier:
/// `else` only after an `if`, `catch`/`finally` only after a `try`, `case`/`default` inside a
/// `switch` block, `yield` inside a `switch` expression, `break` in a loop or `switch`, `continue`
/// in a loop, `this`/`super` outside static code, and `instanceof` only after an operand.
struct JavaKeywordPosition {
    private var inLoop = false
    private var inSwitchBlock = false
    private var inSwitchExpression = false
    private var followsIf = false
    private var followsTry = false
    private var followsOperand = false
    private let isStatic: Bool

    init(tree: JavaSyntaxTree, bytes: [UInt8], offset: Int, isStatic: Bool) {
        self.isStatic = isStatic
        var statement: SyntaxNode?
        var current: SyntaxNode? = tree.node(atByteOffset: offset)
        walk: while let node = current {
            switch node.type {
            case "for_statement", "enhanced_for_statement", "while_statement", "do_statement":
                inLoop = true
            case "switch_block":
                inSwitchBlock = true
                if node.parent?.type == "switch_expression" { inSwitchExpression = true }
            case "method_declaration", "constructor_declaration", "lambda_expression", "class_body", "static_initializer", "program":
                break walk
            default:
                break
            }
            if statement == nil, let parent = node.parent,
               ["block", "constructor_body", "switch_block_statement_group", "switch_rule"].contains(parent.type) {
                statement = node
            }
            current = node.parent
        }
        if let statement, let parent = statement.parent,
           let position = parent.namedChildren.firstIndex(where: { $0.startByte == statement.startByte }), position > 0 {
            let previous = parent.namedChildren[position - 1]
            followsIf = previous.type == "if_statement" && previous.child(byFieldName: "alternative") == nil
            followsTry = previous.type == "try_statement" || previous.type == "try_with_resources_statement"
        }
        let before = JavaCompletionContextClassifier.skipWhitespace(backwardFrom: offset, in: bytes)
        // `try { … } ca|` has no `catch` yet, so tree-sitter turns the `try` into an error and the
        // sibling check above can't see it: look at what opened the block that just closed.
        if !followsTry, before > 0, bytes[before - 1] == UInt8(ascii: "}") {
            followsTry = Self.closesTryOrCatchBlock(bytes: bytes, closingBrace: before - 1)
        }
        if before > 0 {
            let previousByte = bytes[before - 1]
            let previousWord = JavaCompletionContextClassifier.word(endingAt: before, in: bytes)
            followsOperand = previousByte == UInt8(ascii: ")") || previousByte == UInt8(ascii: "]")
                || (previousWord.map { !JavaCompletionProvider.keywords.contains($0) } ?? false)
        }
    }

    private static func closesTryOrCatchBlock(bytes: [UInt8], closingBrace: Int) -> Bool {
        guard let open = matchingOpen(bytes: bytes, close: closingBrace, open: UInt8(ascii: "{"), closeByte: UInt8(ascii: "}")) else { return false }
        let headerEnd = JavaCompletionContextClassifier.skipWhitespace(backwardFrom: open, in: bytes)
        if JavaCompletionContextClassifier.word(endingAt: headerEnd, in: bytes) == "try" { return true }
        guard headerEnd > 0, bytes[headerEnd - 1] == UInt8(ascii: ")"),
              let parenOpen = matchingOpen(bytes: bytes, close: headerEnd - 1, open: UInt8(ascii: "("), closeByte: UInt8(ascii: ")")) else { return false }
        let keywordEnd = JavaCompletionContextClassifier.skipWhitespace(backwardFrom: parenOpen, in: bytes)
        let keyword = JavaCompletionContextClassifier.word(endingAt: keywordEnd, in: bytes)
        return keyword == "catch" || keyword == "try"
    }

    private static func matchingOpen(bytes: [UInt8], close: Int, open: UInt8, closeByte: UInt8) -> Int? {
        var depth = 0
        var index = close
        while index >= 0 {
            if bytes[index] == closeByte { depth += 1 }
            if bytes[index] == open {
                depth -= 1
                if depth == 0 { return index }
            }
            index -= 1
        }
        return nil
    }

    func permits(_ keyword: String) -> Bool {
        switch keyword {
        case "else": return followsIf
        case "catch", "finally": return followsTry
        case "case", "default": return inSwitchBlock
        case "yield": return inSwitchExpression
        case "break": return inLoop || inSwitchBlock
        case "continue": return inLoop
        case "this", "super": return !isStatic
        case "instanceof": return followsOperand
        default: return true
        }
    }
}
