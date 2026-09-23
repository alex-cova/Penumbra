import EditorIntelligence
import Foundation

/// The slower half of Java completion: non-imported classes that beat the in-scope matches,
/// inheritors after `new`, one-hop chains, collection factories, lambdas, and casts.
enum JavaCompletionSuggestions {
    /// Empty-prefix stand-in for IntelliJ's statistics: the usual JDK implementation of each interface.
    static let jdkImplementations: [String: String] = [
        "java.util.List": "java.util.ArrayList",
        "java.util.Collection": "java.util.ArrayList",
        "java.util.Set": "java.util.HashSet",
        "java.util.Map": "java.util.HashMap",
        "java.util.Queue": "java.util.ArrayDeque",
        "java.util.Deque": "java.util.ArrayDeque"
    ]

    private static let objectMethods: Set<String> = [
        "equals", "hashCode", "toString", "getClass", "notify", "notifyAll", "wait", "clone", "finalize"
    ]

    static func advertisement(
        mode: CompletionMode, prefix: String, invocationCount: Int, expected: [JavaTypeRef], offersClasses: Bool
    ) -> String? {
        if mode == .smart { return nil }
        if !expected.isEmpty, !offersClasses {
            return "Smart Type Completion (⌃⇧Space)"
        }
        if invocationCount < 2, !prefix.isEmpty, offersClasses {
            return "Press ⌃Space again to see non-imported classes"
        }
        if !expected.isEmpty {
            return "Smart Type Completion (⌃⇧Space)"
        }
        return nil
    }

    static func smartEmptyText(expected: [JavaTypeRef]) -> String {
        let names = expected.map { JavaCompletionItemFactory.display($0) }
        if names.isEmpty { return "No suggestions" }
        return "No suggestions of type \(names.joined(separator: ", "))"
    }

    /// Keeps expected-type matches, plus `null` / `true` / `false` / `new` where they apply.
    static func filterSmart(_ items: [CompletionItem], expected: [JavaTypeRef], prefix: String) -> [CompletionItem] {
        guard !expected.isEmpty else { return [] }
        let allPrimitive = expected.allSatisfy { if case .primitive = $0 { return true }; return false }
        let expectsBoolean = expected.contains(.primitive(.boolean)) || expected.contains { $0.erasedQualifiedName == "java.lang.Boolean" }
        let expectsClass = expected.contains { if case .classType = $0 { return true }; return false }
        return items.filter { item in
            if item.preselect { return true }
            guard item.kind == .keyword else { return false }
            switch item.label {
            case "null":
                return !allPrimitive && prefix.lowercased().hasPrefix("n")
            case "true", "false":
                return expectsBoolean
            case "new":
                return expectsClass
            default:
                return false
            }
        }
    }

    static func prefixMatches(_ prefix: String, _ name: String) -> Bool {
        CompletionMatcher.matches(prefix, name)
    }

    /// Degree of the tightest in-scope match, and whether anything in scope matched at all.
    static func bestDegree(prefix: String, items: [CompletionItem]) -> (degree: Int, matched: Bool) {
        var best = Int.min
        var matched = false
        for item in items {
            guard let match = CompletionMatcher.match(prefix, in: item.matchText) else { continue }
            matched = true
            best = max(best, match.degree)
        }
        return (best, matched)
    }

    /// A non-imported class is offered on the first completion only when it matches at least as
    /// tightly as the best in-scope item. A repeated Ctrl+Space, or an empty in-scope list, offers
    /// every prefix match.
    static func admitsExtraClass(prefix: String, simpleName: String, invocationCount: Int, best: (degree: Int, matched: Bool)) -> Bool {
        if invocationCount >= 2 || !best.matched { return prefixMatches(prefix, simpleName) }
        guard let match = CompletionMatcher.match(prefix, in: simpleName), match.isStartMatch else { return false }
        return match.degree >= best.degree
    }

    // MARK: - new

    static func isAnonymous(_ stub: JavaClassStub) -> Bool {
        stub.kind == .interfaceKind || stub.modifiers.contains(.abstractFlag)
    }

    // MARK: - Chains, factories, lambdas, casts

    static func chains(
        locals: [JavaLocalVariable], members: [JavaResolvedMember], expected: [JavaTypeRef],
        invocationCount: Int, mode: CompletionMode, fastHasExpectedMatch: Bool,
        factory: JavaCompletionItemFactory, context: JavaResolutionContext, index: JavaIndex,
        assignability: JavaAssignability
    ) async -> [CompletionItem] {
        guard !expected.isEmpty else { return [] }
        guard mode == .smart || invocationCount >= 2 || !fastHasExpectedMatch else { return [] }
        var items: [CompletionItem] = []
        for local in locals.prefix(20) {
            if items.count >= 30 { break }
            let type = await JavaTypeResolver.resolve(local.type, context: context, index: index)
            await appendChains(qualifier: local.name, type: type, callQualifier: false, into: &items, expected: expected, invocationCount: invocationCount, factory: factory, context: context, index: index, assignability: assignability)
        }
        for member in members {
            if items.count >= 30 { break }
            guard case .method(let method, _) = member, method.parameters.isEmpty, !method.modifiers.contains(.staticFlag) else { continue }
            await appendChains(qualifier: method.name, type: method.returnType, callQualifier: true, into: &items, expected: expected, invocationCount: invocationCount, factory: factory, context: context, index: index, assignability: assignability)
        }
        return items
    }

    private static func appendChains(
        qualifier: String, type: JavaTypeRef, callQualifier: Bool, into items: inout [CompletionItem],
        expected: [JavaTypeRef], invocationCount: Int, factory: JavaCompletionItemFactory,
        context: JavaResolutionContext, index: JavaIndex, assignability: JavaAssignability
    ) async {
        if type.erasedQualifiedName == "java.lang.String", invocationCount < 3 { return }
        let lookedUp = await JavaMemberLookup.members(of: type, mode: .instance, context: context, index: index)
        for member in lookedUp {
            guard items.count < 30, case .method(let method, let declaring) = member else { continue }
            guard method.parameters.isEmpty, !method.modifiers.contains(.staticFlag) else { continue }
            if objectMethods.contains(method.name) {
                let builder = declaring.contains("StringBuilder") || declaring.contains("StringBuffer") || declaring.contains("AbstractStringBuilder")
                guard method.name == "toString", builder else { continue }
            }
            guard await JavaCompletionProvider.matchesExpected(method.returnType, expected: expected, assignability: assignability) else { continue }
            let call = callQualifier ? "\(qualifier)()" : qualifier
            let label = "\(call).\(method.name)"
            items.append(CompletionItem(
                label: label, insertText: "\(label)()", kind: .method, range: factory.range, source: "java",
                filterText: label, detail: JavaCompletionItemFactory.display(method.returnType),
                priority: JavaCompletionPriority.inheritedMember, preselect: true, allowsAutoInsert: false
            ))
        }
    }

    static func toArrayConversions(
        locals: [JavaLocalVariable], expected: [JavaTypeRef], factory: JavaCompletionItemFactory
    ) -> [CompletionItem] {
        var items: [CompletionItem] = []
        for type in expected {
            guard case .array(let element) = type else { continue }
            let simple = JavaCompletionItemFactory.display(element)
            for local in locals {
                let erased = local.type.erasedQualifiedName ?? ""
                guard erased == "java.util.Collection" || erased == "java.util.List" || erased == "java.util.Set" else { continue }
                let label = "\(local.name).toArray"
                items.append(CompletionItem(
                    label: label, insertText: "\(local.name).toArray(new \(simple)[0])", kind: .method,
                    range: factory.range, source: "java", filterText: label, detail: "\(simple)[]",
                    labelDetail: "(new \(simple)[0])", priority: JavaCompletionPriority.inheritedMember,
                    preselect: true, allowsAutoInsert: false
                ))
            }
        }
        return items
    }

    static func collectionFactories(
        expected: [JavaTypeRef], prefix: String, imports: [JavaImportDeclaration], factory: JavaCompletionItemFactory,
        importer: JavaImportInserter
    ) -> [CompletionItem] {
        if staticallyImportsCollections(imports) { return [] }
        let expectedNames = Set(expected.compactMap(\.erasedQualifiedName))
        guard !expectedNames.isEmpty else { return [] }
        let catalog: [(String, String, Bool)] = [
            ("emptyList", "java.util.List", false),
            ("emptySet", "java.util.Set", false),
            ("emptyMap", "java.util.Map", false),
            ("singletonList", "java.util.List", true),
            ("singleton", "java.util.Set", true),
            ("singletonMap", "java.util.Map", true),
            ("unmodifiableList", "java.util.List", true),
            ("unmodifiableSet", "java.util.Set", true),
            ("unmodifiableCollection", "java.util.Collection", true),
            ("unmodifiableMap", "java.util.Map", true),
            ("unmodifiableSortedSet", "java.util.SortedSet", true),
            ("unmodifiableSortedMap", "java.util.SortedMap", true)
        ]
        guard let collections = collectionsStub() else { return [] }
        let decision = importer.decision(for: collections)
        var edits: [TextEdit] = []
        if case .addImport(let edit) = decision { edits = [edit] }
        var items: [CompletionItem] = []
        for (name, typeName, needsPrefix) in catalog {
            guard expectedNames.contains(typeName) else { continue }
            if needsPrefix, prefix.isEmpty { continue }
            let takesArguments = needsPrefix
            let insert = "Collections.\(name)()"
            items.append(CompletionItem(
                label: name, insertText: insert, kind: .method, range: factory.range, source: "java",
                filterText: name,
                detail: JavaCompletionItemFactory.display(.classType(qualifiedName: typeName, arguments: [], outer: nil)),
                labelDetail: "()", additionalEdits: edits,
                priority: JavaCompletionPriority.classInScope + JavaCompletionPriority.expectedTypeBonus,
                caretOffset: takesArguments ? ("Collections.\(name)" as NSString).length + 1 : nil,
                preselect: true, allowsAutoInsert: false
            ))
        }
        return items
    }

    private static func staticallyImportsCollections(_ imports: [JavaImportDeclaration]) -> Bool {
        imports.contains { declaration in
            declaration.isStatic && (declaration.qualifiedName == "java.util.Collections" || declaration.qualifiedName.hasPrefix("java.util.Collections."))
        }
    }

    private static func collectionsStub() -> JavaClassStub? {
        JavaClassStub(
            binaryName: "java.util.Collections", qualifiedName: "java.util.Collections", simpleName: "Collections",
            packageName: "java.util", kind: .classKind, modifiers: .publicFlag,
            origin: .source(URL(fileURLWithPath: "/java/util/Collections.java"), nameRange: 0..<0)
        )
    }

    static func functionalTemplates(
        expected: [JavaTypeRef], members: [JavaResolvedMember], factory: JavaCompletionItemFactory,
        context: JavaResolutionContext, index: JavaIndex
    ) async -> [CompletionItem] {
        var items: [CompletionItem] = []
        for type in expected {
            guard let signature = await JavaExpressionTyper.functionalSignature(of: type, context: context, index: index) else { continue }
            let names = parameterNames(signature.parameters)
            let head = names.count == 1 ? names[0] : "(\(names.joined(separator: ", ")))"
            let simple = JavaCompletionItemFactory.display(type)
            items.append(CompletionItem(
                label: "\(head) -> {}", insertText: "\(head) -> ", kind: .snippet, range: factory.range, source: "java",
                filterText: "\(head) ->", detail: simple,
                priority: JavaCompletionPriority.ownMember + JavaCompletionPriority.expectedTypeBonus,
                preselect: true, allowsAutoInsert: false
            ))
            for member in members {
                guard case .method(let method, _) = member, !method.modifiers.contains(.staticFlag) else { continue }
                guard method.parameters.count == signature.parameters.count else { continue }
                guard await returnMatches(method.returnType, signature.returnType, context: context, index: index) else { continue }
                items.append(CompletionItem(
                    label: "this::\(method.name)", insertText: "this::\(method.name)", kind: .method, range: factory.range,
                    source: "java", detail: simple, priority: JavaCompletionPriority.ownMember, preselect: true, allowsAutoInsert: false
                ))
            }
            if let produced = signature.returnType.erasedQualifiedName,
               let stub = await index.classStub(qualifiedName: produced) {
                let arity = signature.parameters.count
                let hasConstructor = stub.methods.contains { $0.isConstructor && $0.parameters.count == arity && !$0.modifiers.contains(.privateFlag) }
                    || (arity == 0 && !stub.methods.contains(where: \.isConstructor))
                if hasConstructor {
                    let name = stub.simpleName
                    items.append(CompletionItem(
                        label: "\(name)::new", insertText: "\(name)::new", kind: .method, range: factory.range, source: "java",
                        detail: simple, priority: JavaCompletionPriority.classInScope, preselect: true, allowsAutoInsert: false
                    ))
                }
            }
        }
        return items
    }

    static func casts(expected: [JavaTypeRef], factory: JavaCompletionItemFactory) -> [CompletionItem] {
        var seen = Set<String>()
        var items: [CompletionItem] = []
        for type in expected {
            let simple = JavaCompletionItemFactory.display(type)
            guard seen.insert(simple).inserted, simple != "void" else { continue }
            items.append(CompletionItem(
                label: simple, insertText: "\(simple)) ", kind: .type, range: factory.range, source: "java",
                detail: "cast", priority: JavaCompletionPriority.classInScope + JavaCompletionPriority.expectedTypeBonus,
                preselect: true, allowsAutoInsert: false
            ))
        }
        return items
    }

    private static func parameterNames(_ types: [JavaTypeRef]) -> [String] {
        var used = Set<String>()
        return types.enumerated().map { index, type in
            var name = JavaCompletionItemFactory.display(type)
            name = name.replacingOccurrences(of: "[]", with: "")
            name = String(name.prefix { $0 != "<" })
            if let first = name.first {
                name = first.lowercased() + name.dropFirst()
            }
            if name.isEmpty || name == "?" { name = "arg" }
            if used.contains(name) { name = "\(name)\(index + 1)" }
            used.insert(name)
            return name
        }
    }

    private static func returnMatches(_ actual: JavaTypeRef, _ expected: JavaTypeRef, context: JavaResolutionContext, index: JavaIndex) async -> Bool {
        if expected == .void { return actual == .void }
        let assignability = JavaAssignability(index: index, context: context)
        return await JavaCompletionProvider.matchesExpected(actual, expected: [expected], assignability: assignability)
    }
}
