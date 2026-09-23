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
        guard context.document.languageIdentifier == "java" else { return [] }
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
        guard let tree = JavaSyntaxParser().parse(text) else { return nil }
        let stubs = JavaSourceStubBuilder.build(tree: tree, url: url)
        cachedParse = (text, tree, stubs)
        return (tree, stubs)
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

    private func provideInScope(context: CompletionContext) async -> [CompletionItem] {
        guard !context.document.contentSnapshot.isElided else { return [] }
        let text = Self.repairedText(context.document.text, insertingDummyAt: context.cursor.position.utf16Offset)
        let fileURL = context.document.url ?? URL(fileURLWithPath: "/unsaved/\(context.document.id).java")
        guard let (tree, fileStubs) = parse(text, url: fileURL) else { return [] }

        let bytes = Array(text.utf8)
        let prefixStart = Self.utf8ByteOffset(forUTF16Offset: context.range.start.utf16Offset, in: text)
        let cursor = Self.utf8ByteOffset(forUTF16Offset: context.cursor.position.utf16Offset, in: text)
        let resolutionContext = Self.resolutionContext(in: tree, fileStubs: fileStubs, atByteOffset: min(prefixStart, cursor))
        let request = Request(
            text: text, bytes: bytes, tree: tree, fileStubs: fileStubs, prefix: context.prefix,
            prefixStart: prefixStart, cursor: cursor, context: resolutionContext,
            factory: JavaCompletionItemFactory(range: context.range, source: name),
            importer: JavaImportInserter(text: text, bytes: bytes, tree: tree, fileStubs: fileStubs),
            invocationCount: context.invocationCount,
            isManual: context.trigger == .manual,
            index: index
        )

        let site = JavaCompletionContextClassifier.classify(bytes: bytes, tree: tree, prefixStart: prefixStart)
        javaCompletionLog.debug("java site=\(String(describing: site), privacy: .public) enclosing=\(resolutionContext.enclosingTypeQualifiedNames, privacy: .public)")
        switch site {
        case .stringOrComment:
            return []
        case .memberAccess(let dotOffset):
            return await memberAccessItems(dotOffset: dotOffset, source: text, request: request)
        case .methodReference(let colonOffset):
            return await methodReferenceItems(colonOffset: colonOffset, request: request)
        case .importPath(let qualifier, let isStatic):
            return await importItems(qualifier: qualifier, isStatic: isStatic, request: request)
        case .packagePath(let qualifier):
            return await index.subpackages(of: qualifier).map { request.factory.packageItem($0) }
        case .annotation:
            return await annotationItems(request: request)
        case .annotationAttribute(let annotationName):
            return await annotationAttributeItems(annotationName: annotationName, request: request)
        case .newExpression:
            return await newExpressionItems(request: request)
        case .typeOnly(let keyword):
            return await typeOnlyItems(keyword: keyword, request: request)
        case .caseLabel(let selectorText):
            let items = await caseLabelItems(selectorText: selectorText, request: request)
            return items.isEmpty ? await statementItems(request: request) : items
        case .classBody:
            return await classBodyItems(request: request)
        case .topLevel:
            return Self.topLevelKeywords.map { request.factory.keywordItem($0) }
        case .statement:
            return await statementItems(request: request)
        }
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
            typeParameterNames: enclosing.typeParameterNames.union(methodTypeParameters(in: tree, atByteOffset: byteOffset))
        )
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
        for member in members {
            let matches = await Self.matchesExpected(member.valueType, expected: expected, assignability: assignability)
            items.append(request.factory.memberItem(member, receiverQualifiedName: receiverName ?? "<array>", expectedMatch: matches))
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
            items.append(request.factory.classItem(match.stub, importDecision: decision, priority: classPriority(match.stub, decision: decision)))
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

    private func newExpressionItems(request: Request) async -> [CompletionItem] {
        let expected = await JavaExpectedType.infer(at: Self.newKeywordStart(before: request.prefixStart, bytes: request.bytes), request: request.semantic)
        let assignability = JavaAssignability(index: index, context: request.context)
        var stubs: [JavaClassStub] = []
        if request.prefix.isEmpty {
            // Smart `new |`: the expected class itself (when instantiable).
            for type in expected {
                if let name = type.erasedQualifiedName, let stub = await index.classStub(qualifiedName: name) {
                    stubs.append(stub)
                }
            }
        } else {
            stubs = await index.classes(matching: request.prefix, limit: classNameLimit(request)).map(\.stub)
        }
        var items: [CompletionItem] = []
        for stub in stubs where stub.kind != .enumKind && stub.kind != .annotationKind {
            let decision = request.importer.decision(for: stub)
            let classType = JavaTypeRef.classType(qualifiedName: stub.qualifiedName, arguments: [], outer: nil)
            let matches = await Self.matchesExpected(classType, expected: expected, assignability: assignability)
            items.append(request.factory.constructorItem(stub, importDecision: decision, priority: classPriority(stub, decision: decision), expectedMatch: matches))
        }
        return items
    }

    private static func newKeywordStart(before prefixStart: Int, bytes: [UInt8]) -> Int {
        let end = JavaCompletionContextClassifier.skipWhitespace(backwardFrom: prefixStart, in: bytes)
        return max(0, end - 3)
    }

    // MARK: - Type-only positions

    private func typeOnlyItems(keyword: String, request: Request) async -> [CompletionItem] {
        var items: [CompletionItem] = []
        for typeParameter in request.context.typeParameterNames.sorted() {
            items.append(CompletionItem(
                label: typeParameter, insertText: typeParameter, kind: .type, range: request.factory.range, source: name,
                priority: JavaCompletionPriority.local
            ))
        }
        guard !request.prefix.isEmpty else { return items }
        for match in await index.classes(matching: request.prefix, limit: classNameLimit(request)) {
            let stub = match.stub
            switch keyword {
            case "implements":
                guard stub.kind == .interfaceKind else { continue }
            case "extends":
                guard stub.kind == .classKind || stub.kind == .interfaceKind, !stub.modifiers.contains(.finalFlag) else { continue }
            default:
                break
            }
            let decision = request.importer.decision(for: stub)
            var priority = classPriority(stub, decision: decision)
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

    private func classBodyItems(request: Request) async -> [CompletionItem] {
        var items = Self.memberModifierKeywords.map { request.factory.keywordItem($0) }
        items += await classNameItems(request: request)
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
        for member in members {
            guard case .method(let method, let declaringClass) = member, declaringClass != selfName else { continue }
            let modifiers = method.modifiers
            guard !modifiers.contains(.finalFlag), !modifiers.contains(.staticFlag), !modifiers.contains(.privateFlag) else { continue }
            let declaringKind = await index.classStub(qualifiedName: declaringClass)?.kind
            items.append(request.factory.overrideItem(
                method, declaringClass: declaringClass, isInterfaceMethod: declaringKind == .interfaceKind, indentation: indentation
            ))
        }
        return items
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

    private func statementItems(request: Request) async -> [CompletionItem] {
        let rawLocals = JavaLocalScope.locals(in: request.tree, atByteOffset: request.cursor)
        let locals = await JavaExpressionTyper.resolvingVarLocals(rawLocals, context: request.context, index: index)
        let semantic = JavaSemanticRequest(source: request.text, bytes: request.bytes, tree: request.tree, locals: locals, context: request.context, index: index)
        let expected = await JavaExpectedType.infer(at: request.prefixStart, request: semantic)
        let assignability = JavaAssignability(index: index, context: request.context)
        var items: [CompletionItem] = []

        for local in locals {
            let matches = await Self.matchesExpected(local.type, expected: expected, assignability: assignability)
            items.append(request.factory.localItem(local, expectedMatch: matches))
        }

        let isStatic = Self.isStaticContext(tree: request.tree, offset: request.cursor)
        var seenMembers = Set<String>()
        for (depth, enclosing) in request.context.enclosingTypeQualifiedNames.enumerated() {
            let selfType = JavaTypeRef.classType(qualifiedName: enclosing, arguments: [], outer: nil)
            let mode: JavaMemberLookupMode = isStatic ? .staticOnly : .instance
            for member in await JavaMemberLookup.members(of: selfType, mode: mode, context: request.context, index: index) {
                let key = Self.memberKey(member)
                guard seenMembers.insert(key).inserted else { continue }
                let matches = await Self.matchesExpected(member.valueType, expected: expected, assignability: assignability)
                let base: Double? = depth == 0 ? nil : JavaCompletionPriority.outerMember
                items.append(request.factory.memberItem(member, receiverQualifiedName: enclosing, basePriority: base, expectedMatch: matches))
            }
        }
        for member in await JavaStaticImports.members(context: request.context, index: index) {
            guard seenMembers.insert(Self.memberKey(member)).inserted else { continue }
            let matches = await Self.matchesExpected(member.valueType, expected: expected, assignability: assignability)
            items.append(request.factory.memberItem(member, receiverQualifiedName: nil, basePriority: JavaCompletionPriority.staticImport, expectedMatch: matches))
        }

        items += await classNameItems(request: request)

        if !request.prefix.isEmpty || request.isManual {
            let expectsBoolean = expected.contains(.primitive(.boolean)) || expected.contains { $0.erasedQualifiedName == "java.lang.Boolean" }
            for keyword in Self.statementKeywords {
                var priority = JavaCompletionPriority.keyword
                if expectsBoolean, keyword == "true" || keyword == "false" { priority += JavaCompletionPriority.expectedTypeBonus }
                if !expected.isEmpty, keyword == "new" || keyword == "null" { priority += 1 }
                items.append(request.factory.keywordItem(keyword, priority: priority))
            }
        }
        return items
    }

    /// Classes matching the typed prefix (none for an empty prefix -- like IntelliJ, class names
    /// only come in once something is typed), auto-imported on accept.
    private func classNameItems(request: Request) async -> [CompletionItem] {
        guard !request.prefix.isEmpty else { return [] }
        var items: [CompletionItem] = []
        let ownNames = Set(request.context.enclosingTypeQualifiedNames)
        for match in await index.classes(matching: request.prefix, limit: classNameLimit(request)) {
            let decision = ownNames.contains(match.stub.qualifiedName) ? .none : request.importer.decision(for: match.stub)
            items.append(request.factory.classItem(match.stub, importDecision: decision, priority: classPriority(match.stub, decision: decision)))
        }
        return items
    }

    private func classNameLimit(_ request: Request) -> Int {
        request.invocationCount >= 2 ? classNameCompletionLimit * 4 : classNameCompletionLimit
    }

    /// Same package or already imported ranks above `java.*`, which ranks above everything else.
    private func classPriority(_ stub: JavaClassStub, decision: JavaImportInserter.Decision) -> Double {
        if case .none = decision { return JavaCompletionPriority.classInScope }
        if stub.packageName.hasPrefix("java.") { return JavaCompletionPriority.classOther + 0.25 }
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
