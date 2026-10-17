import EditorIntelligence
import Foundation

/// `runs.forach(...)` where the receiver's class declares `forEach` but no `forach`.
/// Syntax highlighting stays silent on it (it parses); what flags it in an IDE is name
/// resolution, which this rule performs against the index.
///
/// It reports qualified accesses (`list.ad(x)`, `Util.twic(1)`, `"abc".lengt()`,
/// `p.zzz`, `String::lengt`) and implicit-`this` calls (`helpr()`) only when the
/// receiver's class is known **and closed** (every supertype indexed, no Lombok in the
/// chain): anything unknowable stays silent, and a name that merely grows inside an
/// otherwise complete expression is guarded by the prefix rule below. Arity and overload
/// mismatches are `javac`'s job: a name that exists never reports.
enum JavaUnresolvedMemberInspection: JavaTypedInspection {
    static let rule = JavaInspectionRule.unresolvedMember
    static let nodeTypes: Set<String> = ["method_invocation", "field_access", "method_reference"]
    private static let maxResolutions = 300
    private static let objectType = JavaTypeRef.classType(qualifiedName: "java.lang.Object", arguments: [], outer: nil)
    private static let annotationType = JavaTypeRef.classType(qualifiedName: "java.lang.annotation.Annotation", arguments: [], outer: nil)
    private static let typeDeclarations: Set<String> = [
        "class_declaration", "interface_declaration", "enum_declaration", "record_declaration", "annotation_type_declaration",
    ]

    static func check(nodes: [SyntaxNode], context: JavaInspectionContext, report: (JavaInspection) -> Void) async {
        // Extension methods make any name valid on any receiver: the whole file is unknowable.
        if lombokImports(in: context).extensionMethods { return }
        let pass = Pass(context: context)
        for node in nodes {
            switch node.type {
            case "method_invocation":
                await checkInvocation(node, pass: pass, report: report)
            case "field_access":
                await checkFieldAccess(node, pass: pass, report: report)
            case "method_reference":
                await checkMethodReference(node, pass: pass, report: report)
            default:
                break
            }
        }
    }

    // MARK: - Qualified accesses

    private static func checkInvocation(_ node: SyntaxNode, pass: Pass, report: (JavaInspection) -> Void) async {
        guard let nameNode = node.child(byFieldName: "name"), !nameNode.text.isEmpty else { return }
        guard let object = node.child(byFieldName: "object") else {
            await checkImplicit(name: nameNode.text, nameNode: nameNode, node: node, pass: pass, report: report)
            return
        }
        // `this.m()`, `super.m()`, `X.this.m()`, `X.super.m()` resolve against the
        // enclosing types, like a bare `m()` (`this` may name an enclosing class).
        if isThisOrSuperReference(object) {
            await checkImplicit(name: nameNode.text, nameNode: nameNode, node: node, pass: pass, report: report)
            return
        }
        guard let (key, declaredName) = receiverKey(for: object) else { return }
        guard let receiver = await typedInvocationReceiver(key: key, node: node, nameNode: nameNode, declaredName: declaredName, pass: pass) else { return }
        guard let known = await memberNames(of: receiver.type, using: receiver.context, pass: pass) else { return }
        // A method invocation always reports: the prefix guard below is only for accesses
        // without an argument list, so `list.ad(x)` flags while typing `add`.
        guard !known.methods.contains(nameNode.text) else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "Cannot resolve method '\(nameNode.text)' in '\(simpleName(of: receiver.type))'", node: nameNode
        ))
    }

    private static func checkFieldAccess(_ node: SyntaxNode, pass: Pass, report: (JavaInspection) -> Void) async {
        guard let object = node.child(byFieldName: "object"),
              let fieldNode = node.child(byFieldName: "field"), !fieldNode.text.isEmpty else { return }
        // `Foo.class`, `X.this` and `X.super` are not member lookups.
        if fieldNode.text == "class" || fieldNode.text == "this" || fieldNode.text == "super" { return }
        // `this.x` and `super.x` name the enclosing type's members, which the implicit
        // path owns for calls; fields there are out of v1.
        if isThisOrSuperReference(object) { return }
        guard let (key, declaredName) = receiverKey(for: object) else { return }
        guard let receiver = await typedFieldReceiver(key: key, node: node, fieldNode: fieldNode, declaredName: declaredName, pass: pass) else { return }
        guard let known = await memberNames(of: receiver.type, using: receiver.context, pass: pass) else { return }
        // `x.size` where only `size()` exists is a genuine error, but `p.si` while
        // typing `size` is not: silent when the name is a strict prefix of any member.
        guard !known.fields.contains(fieldNode.text), !known.nested.contains(fieldNode.text) else { return }
        let all = known.methods.union(known.fields).union(known.nested)
        guard !all.contains(where: { $0 != fieldNode.text && $0.hasPrefix(fieldNode.text) }) else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "Cannot resolve symbol '\(fieldNode.text)'", node: fieldNode
        ))
    }

    private static func checkMethodReference(_ node: SyntaxNode, pass: Pass, report: (JavaInspection) -> Void) async {
        let named = node.namedChildren
        guard named.count >= 2, let object = named.first, let nameNode = named.last,
              nameNode.type == "identifier", !nameNode.text.isEmpty else { return }
        // Constructor references (`Foo::new`, `int[]::new`) are not member lookups.
        if nameNode.text == "new" || node.text.hasSuffix("::new") { return }
        if object.type == "this" || object.type == "super" {
            await checkImplicit(name: nameNode.text, nameNode: nameNode, node: node, pass: pass, report: report)
            return
        }
        guard let (key, declaredName) = receiverKey(for: object) else { return }
        guard let receiver = await typedMethodReferenceReceiver(key: key, node: node, object: object, nameNode: nameNode, declaredName: declaredName, pass: pass) else { return }
        guard let known = await memberNames(of: receiver.type, using: receiver.context, pass: pass) else { return }
        guard !known.methods.contains(nameNode.text) else { return }
        // Like a field access, a reference has no argument list: `String::lengt` stays
        // silent while it is still a prefix of `length`.
        let all = known.methods.union(known.fields)
        guard !all.contains(where: { $0 != nameNode.text && $0.hasPrefix(nameNode.text) }) else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "Cannot resolve method '\(nameNode.text)' in '\(simpleName(of: receiver.type))'", node: nameNode
        ))
    }

    // MARK: - Receiver gate

    /// The memo key for a receiver, or nil when v1 does not trust it: call chains, casts,
    /// `new`, array access, conditionals and anything that is neither a declared type nor
    /// a type-rooted identifier chain.
    private static func receiverKey(for object: SyntaxNode) -> (key: String, declaredName: String?)? {
        // Declared receivers: locals, parameters, fields, `this.f`, literals and string
        // concatenation. Nil for `var` and everything inferred.
        if let declared = JavaDeclaredTypes.type(of: object) {
            return ("D:\(declared.name)\(declared.isArray ? "[]" : "")", declared.name)
        }
        guard let root = typeRootText(of: object) else { return nil }
        return ("T:\(root)", nil)
    }

    /// An uppercase-first `identifier` that did not type, or a `field_access` chain of
    /// identifiers rooted at one: `Math`, `Map.Entry`, `System.out`.
    private static func typeRootText(of object: SyntaxNode) -> String? {
        switch object.unparenthesized.type {
        case "identifier":
            let text = object.text
            guard let first = text.first, first.isUppercase else { return nil }
            return text
        case "field_access":
            var parts: [String] = []
            var current: SyntaxNode? = object
            while let access = current, access.type == "field_access" {
                guard let field = access.child(byFieldName: "field"), field.type == "identifier" else { return nil }
                parts.append(field.text)
                current = access.child(byFieldName: "object")
            }
            guard let root = current, root.type == "identifier",
                  let first = root.text.first, first.isUppercase else { return nil }
            parts.append(root.text)
            return parts.reversed().joined(separator: ".")
        default:
            return nil
        }
    }

    private static func isThisOrSuperReference(_ object: SyntaxNode) -> Bool {
        let node = object.unparenthesized
        if node.type == "this" || node.type == "super" { return true }
        if node.type == "identifier", node.text == "this" || node.text == "super" { return true }
        if node.type == "field_access", let field = node.child(byFieldName: "field"),
           field.text == "this" || field.text == "super" { return true }
        return false
    }

    private static func typedInvocationReceiver(
        key: String, node: SyntaxNode, nameNode: SyntaxNode, declaredName: String?, pass: Pass
    ) async -> TypedReceiver? {
        if let cached = cachedReceiver(key: key, pass: pass) { return cached }
        if pass.unknownReceivers.contains(key) || pass.resolutions >= maxResolutions { return nil }
        pass.resolutions += 1
        let session = JavaInspectionSupport.session(for: pass.context, at: node.startByte)
        // `T extends A & B` keeps only `A`, so a type parameter's members are unknowable.
        if let declaredName, session.context.typeParameterNames.contains(declaredName) {
            pass.unknownReceivers.insert(key)
            return nil
        }
        guard let info = await session.receiverInfo(of: node, nameNode: nameNode), info.packageName == nil else {
            pass.unknownReceivers.insert(key)
            return nil
        }
        return storeReceiver(key: key, type: erasedReceiverType(info.type), context: session.context, pass: pass)
    }

    private static func typedFieldReceiver(
        key: String, node: SyntaxNode, fieldNode: SyntaxNode, declaredName: String?, pass: Pass
    ) async -> TypedReceiver? {
        if let cached = cachedReceiver(key: key, pass: pass) { return cached }
        if pass.unknownReceivers.contains(key) || pass.resolutions >= maxResolutions { return nil }
        pass.resolutions += 1
        let session = JavaInspectionSupport.session(for: pass.context, at: node.startByte)
        if let declaredName, session.context.typeParameterNames.contains(declaredName) {
            pass.unknownReceivers.insert(key)
            return nil
        }
        guard let dot = dotBefore(fieldNode, in: session.source),
              let info = await JavaExpressionTyper.receiverInfo(
                  source: session.source, realTree: session.tree, dotOffset: dot,
                  context: session.context, index: session.index
              ), info.packageName == nil else {
            pass.unknownReceivers.insert(key)
            return nil
        }
        return storeReceiver(key: key, type: erasedReceiverType(info.type), context: session.context, pass: pass)
    }

    private static func typedMethodReferenceReceiver(
        key: String, node: SyntaxNode, object: SyntaxNode, nameNode: SyntaxNode, declaredName: String?, pass: Pass
    ) async -> TypedReceiver? {
        if let cached = cachedReceiver(key: key, pass: pass) { return cached }
        if pass.unknownReceivers.contains(key) || pass.resolutions >= maxResolutions { return nil }
        pass.resolutions += 1
        let session = JavaInspectionSupport.session(for: pass.context, at: node.startByte)
        if let declaredName, session.context.typeParameterNames.contains(declaredName) {
            pass.unknownReceivers.insert(key)
            return nil
        }
        guard let separator = doubleColonOffset(objectEnd: object.endByte, nameStart: nameNode.startByte, in: session.source),
              let info = await JavaExpressionTyper.receiverInfo(
                  source: session.source, realTree: session.tree, dotOffset: separator,
                  context: session.context, index: session.index
              ), info.packageName == nil else {
            pass.unknownReceivers.insert(key)
            return nil
        }
        return storeReceiver(key: key, type: erasedReceiverType(info.type), context: session.context, pass: pass)
    }

    /// Only class and array receivers carry checkable members; type arguments only matter
    /// for the next step of a chain, which v1 does not take.
    private static func erasedReceiverType(_ type: JavaTypeRef) -> JavaTypeRef? {
        switch type {
        case .classType, .array:
            return type
        default:
            return nil
        }
    }

    private static func dotBefore(_ node: SyntaxNode, in source: String) -> Int? {
        let bytes = Array(source.utf8)
        var index = node.startByte - 1
        while index >= 0, index < bytes.count {
            let byte = bytes[index]
            if byte == 32 || byte == 9 || byte == 10 || byte == 13 {
                index -= 1
                continue
            }
            return byte == UInt8(ascii: ".") ? index : nil
        }
        return nil
    }

    private static func doubleColonOffset(objectEnd: Int, nameStart: Int, in source: String) -> Int? {
        let bytes = Array(source.utf8)
        var index = objectEnd
        while index < nameStart, index < bytes.count {
            if bytes[index] == UInt8(ascii: ":") { return index }
            index += 1
        }
        return nil
    }

    // MARK: - Member sets

    private static func memberNames(of type: JavaTypeRef, using context: JavaResolutionContext, pass: Pass) async -> MemberNames? {
        switch type {
        case .array(let element):
            return await arrayMemberNames(elementType: element, using: context, pass: pass)
        case .classType(let qualifiedName, _, _):
            return await classMemberNames(qualifiedName: qualifiedName, using: context, pass: pass)
        default:
            return nil
        }
    }

    private static func classMemberNames(qualifiedName: String, using context: JavaResolutionContext, pass: Pass) async -> MemberNames? {
        if let known = pass.memberSets[qualifiedName] { return known }
        if pass.openClasses.contains(qualifiedName) { return nil }
        let index = pass.context.index
        guard let nested = await JavaMemberLookup.closedHierarchy(of: qualifiedName, context: context, index: index) else {
            pass.openClasses.insert(qualifiedName)
            return nil
        }
        let type = JavaTypeRef.classType(qualifiedName: qualifiedName, arguments: [], outer: nil)
        // Both modes: `.instance` drops static interface methods (`List.of`), and
        // `.staticOnly` drops instance methods (`String::length` is a valid unbound
        // method reference). An inaccessible member is `javac`'s "has private access",
        // not "cannot resolve", so the access check stays off.
        let instance = await JavaMemberLookup.members(of: type, mode: .instance, context: context, index: index, checkAccess: false)
        let statics = await JavaMemberLookup.members(of: type, mode: .staticOnly, context: context, index: index, checkAccess: false)
        // Interfaces never queue `Object` in the walk, but JLS 9.2 gives them its methods.
        let object = qualifiedName == "java.lang.Object" ? [] : await JavaMemberLookup.members(
            of: objectType, mode: .instance, context: context, index: index, checkAccess: false
        )
        let built = makeMemberNames(from: instance + statics + object, nested: nested)
        pass.memberSets[qualifiedName] = built
        return built
    }

    private static func arrayMemberNames(elementType: JavaTypeRef, using context: JavaResolutionContext, pass: Pass) async -> MemberNames? {
        if let known = pass.memberSets["<array>"] { return known }
        if pass.openClasses.contains("<array>") { return nil }
        let index = pass.context.index
        guard await index.classStub(qualifiedName: "java.lang.Object") != nil else {
            pass.openClasses.insert("<array>")
            return nil
        }
        let array = await JavaMemberLookup.members(
            of: .array(element: elementType), mode: .instance, context: context, index: index, checkAccess: false
        )
        let object = await JavaMemberLookup.members(of: objectType, mode: .instance, context: context, index: index, checkAccess: false)
        let built = makeMemberNames(from: array + object, nested: [])
        pass.memberSets["<array>"] = built
        return built
    }

    private static func makeMemberNames(from members: [JavaResolvedMember], nested: Set<String>) -> MemberNames {
        var methods = Set<String>()
        var fields = Set<String>()
        for member in members {
            switch member {
            case .method(let stub, _):
                methods.insert(stub.name)
            case .field(let stub, _):
                fields.insert(stub.name)
            }
        }
        return MemberNames(methods: methods, fields: fields, nested: nested)
    }

    private static func simpleName(of type: JavaTypeRef) -> String {
        switch type {
        case .classType(let qualifiedName, _, _):
            return String(qualifiedName.split(separator: ".").last ?? Substring(qualifiedName))
        case .array(let element):
            return "\(simpleName(of: element))[]"
        default:
            return type.simpleDisplayName
        }
    }

    // MARK: - Implicit `this`

    private static func checkImplicit(
        name: String, nameNode: SyntaxNode, node: SyntaxNode, pass: Pass, report: (JavaInspection) -> Void
    ) async {
        // `@Data` gives the class its own getters, which never appear in source stubs.
        if lombokImports(in: pass.context).any { return }
        let session = JavaInspectionSupport.session(for: pass.context, at: node.startByte)
        let data = await implicitData(for: node, session: session, pass: pass)
        guard !data.open, !data.methods.contains(name) else { return }
        // Locals cannot be invoked in Java, so the only scopes are enclosing types and
        // static imports; the message names the innermost enclosing type.
        guard let display = data.displayName else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "Cannot resolve method '\(name)' in '\(display)'", node: nameNode
        ))
    }

    /// The method names reachable without a receiver at `node`: every enclosing type's own
    /// and inherited members, single static imports, on-demand static owners and `Object`.
    /// `open` is true when any scope was unknowable (an unresolved or open supertype, an
    /// unindexed on-demand static owner, a missing `Object`), in which case the answer is
    /// unknown and the caller stays silent. One entry per innermost body per pass.
    private static func implicitData(for node: SyntaxNode, session: JavaNavigationSession, pass: Pass) async -> ImplicitData {
        let key = innermostBodyRange(of: node)
        if let cached = pass.implicitScopes[key] { return cached }
        let context = session.context
        let index = session.index
        var methods = Set<String>()
        var open = false
        var displayName: String? = nil
        let scopes = enclosingScopes(of: node)
        // Qualified names for the named scopes, innermost first, so each finds its stub in
        // the current file (current even when the file is not indexed yet).
        let prefix = context.packageName.isEmpty ? "" : "\(context.packageName)."
        var running = ""
        var qualifiedOutermostFirst: [String] = []
        for scope in scopes.reversed() {
            if case .named(let decl) = scope, let name = decl.child(byFieldName: "name")?.text {
                running = running.isEmpty ? name : "\(running).\(name)"
                qualifiedOutermostFirst.append("\(prefix)\(running)")
            }
        }
        let qualified = qualifiedOutermostFirst.reversed()
        var namedIndex = 0
        let file = pass.context.file
        scopeLoop: for scope in scopes {
            switch scope {
            case .named(let decl):
                let name = qualified[qualified.index(qualified.startIndex, offsetBy: namedIndex)]
                namedIndex += 1
                if displayName == nil { displayName = decl.child(byFieldName: "name")?.text }
                if let stub = file.classes.first(where: { $0.qualifiedName == name }) {
                    methods.formUnion(stub.methods.filter { !$0.isConstructor }.map(\.name))
                    var supers: [JavaTypeRef] = []
                    if let superclass = stub.superclass {
                        supers.append(superclass)
                    } else if stub.kind == .classKind || stub.kind == .enumKind || stub.kind == .recordKind {
                        supers.append(objectType)
                    } else if stub.kind == .annotationKind {
                        supers.append(annotationType)
                    }
                    supers.append(contentsOf: stub.interfaces)
                    await unionSupertypeMethods(supers, into: &methods, open: &open, session: session)
                } else {
                    // A local type: no stub, so its members come from the tree (plus the
                    // synthesized enum/record members, which never appear in the AST).
                    methods.formUnion(treeMethodNames(of: decl))
                    if decl.type == "enum_declaration" { methods.formUnion(["values", "valueOf"]) }
                    if decl.type == "record_declaration" { methods.formUnion(recordComponents(of: decl)) }
                    await unionSupertypeMethods(declaredSupertypes(of: decl), into: &methods, open: &open, session: session)
                }
            case .anonymous(let body, let creation):
                methods.formUnion(treeMethodNames(of: body))
                // An enum-constant body adds nothing of its own: the enum itself is an
                // outer scope and contributes its members (and its openness) there.
                guard let creation, let typeNode = creation.child(byFieldName: "type") else { continue scopeLoop }
                let resolved = await JavaTypeResolver.resolve(JavaTypeNodeConverter.convert(typeNode), context: context, index: index)
                guard case .classType(let qualifiedName, _, _) = resolved,
                      await JavaMemberLookup.closedHierarchy(of: qualifiedName, context: context, index: index) != nil else {
                    open = true
                    continue scopeLoop
                }
                let found = await JavaMemberLookup.members(
                    of: resolved, mode: .instance, context: context, index: index, checkAccess: false
                )
                for member in found {
                    if case .method(let stub, _) = member { methods.insert(stub.name) }
                }
            }
        }
        // Single static imports name their member outright; on-demand owners need the index.
        for imp in context.imports where imp.isStatic && !imp.isOnDemand {
            if let last = imp.qualifiedName.split(separator: ".").last { methods.insert(String(last)) }
        }
        for imp in context.imports where imp.isStatic && imp.isOnDemand {
            if await index.classStub(qualifiedName: imp.qualifiedName) == nil { open = true }
        }
        if !open {
            for member in await JavaStaticImports.members(context: context, index: index) {
                if case .method(let stub, _) = member { methods.insert(stub.name) }
            }
        }
        if await index.classStub(qualifiedName: "java.lang.Object") == nil {
            open = true
        } else {
            let found = await JavaMemberLookup.members(of: objectType, mode: .instance, context: context, index: index, checkAccess: false)
            for member in found {
                if case .method(let stub, _) = member { methods.insert(stub.name) }
            }
        }
        let built = ImplicitData(methods: methods, open: open, displayName: displayName)
        pass.implicitScopes[key] = built
        return built
    }

    /// Inherited methods of `supers`: static interface methods are not inherited, so
    /// `.instance` is exactly right; the static-vs-instance caller context is ignored
    /// (a different `javac` error). Any unresolvable or open supertype makes the answer
    /// unknown instead.
    private static func unionSupertypeMethods(
        _ supers: [JavaTypeRef], into methods: inout Set<String>, open: inout Bool, session: JavaNavigationSession
    ) async {
        for sup in supers {
            let resolved = await JavaTypeResolver.resolve(sup, context: session.context, index: session.index)
            guard case .classType(let qualifiedName, _, _) = resolved,
                  await JavaMemberLookup.closedHierarchy(of: qualifiedName, context: session.context, index: session.index) != nil else {
                open = true
                continue
            }
            let found = await JavaMemberLookup.members(
                of: resolved, mode: .instance, context: session.context, index: session.index, checkAccess: false
            )
            for member in found {
                if case .method(let stub, _) = member { methods.insert(stub.name) }
            }
        }
    }

    /// The enclosing type scopes innermost first: named declarations, anonymous class
    /// bodies (`new X() { ... }`) with their creation, and enum-constant bodies (whose
    /// type is the enclosing enum, an outer scope).
    private static func enclosingScopes(of node: SyntaxNode) -> [ImplicitScope] {
        var scopes: [ImplicitScope] = []
        var current = node.parent
        while let ancestor = current {
            if typeDeclarations.contains(ancestor.type), ancestor.child(byFieldName: "name") != nil {
                scopes.append(.named(ancestor))
            } else if ancestor.type == "class_body", let parent = ancestor.parent,
                      parent.type == "object_creation_expression" || parent.type == "enum_constant" {
                scopes.append(.anonymous(body: ancestor, creation: parent.type == "object_creation_expression" ? parent : nil))
            }
            current = ancestor.parent
        }
        return scopes
    }

    /// The nearest scope boundary: every node sharing it has the same enclosing chain,
    /// so one entry covers them all.
    private static func innermostBodyRange(of node: SyntaxNode) -> Range<Int> {
        var current: SyntaxNode? = node
        while let ancestor = current {
            if typeDeclarations.contains(ancestor.type), ancestor.child(byFieldName: "name") != nil {
                return ancestor.byteRange
            }
            if ancestor.type == "class_body", let parent = ancestor.parent,
               parent.type == "object_creation_expression" || parent.type == "enum_constant" {
                return ancestor.byteRange
            }
            current = ancestor.parent
        }
        return node.tree.rootNode.byteRange
    }

    /// Method names declared directly in a body or declaration node (constructors excluded:
    /// `this(...)` is not a `method_invocation`).
    private static func treeMethodNames(of scope: SyntaxNode) -> Set<String> {
        let body = typeDeclarations.contains(scope.type) ? scope.child(byFieldName: "body") : scope
        guard let body else { return [] }
        var containers = [body]
        if let declarations = body.firstNamedChild(ofType: "enum_body_declarations") { containers.append(declarations) }
        var names = Set<String>()
        for container in containers {
            for method in container.namedChildren(ofType: "method_declaration") {
                if let name = method.child(byFieldName: "name") { names.insert(name.text) }
            }
        }
        return names
    }

    /// Record component names, whose accessors never appear in the AST but behave like methods.
    private static func recordComponents(of decl: SyntaxNode) -> Set<String> {
        guard let parameters = decl.child(byFieldName: "parameters") else { return [] }
        var names = Set<String>()
        for component in parameters.namedChildren(ofType: "formal_parameter") {
            if let name = component.child(byFieldName: "name") { names.insert(name.text) }
        }
        return names
    }

    /// The supertypes written on a declaration node: `extends`, `implements`, and
    /// `extends` of interfaces. Enums and records resolve their implicit superclass by
    /// name, so a missing `java.lang.Enum`/`Record` reads as open rather than empty.
    private static func declaredSupertypes(of decl: SyntaxNode) -> [JavaTypeRef] {
        var supers: [JavaTypeRef] = []
        if let superclass = decl.child(byFieldName: "superclass")?.namedChildren.first {
            supers.append(JavaTypeNodeConverter.convert(superclass))
        } else if decl.type == "enum_declaration" {
            supers.append(.unresolved(simpleName: "Enum", arguments: []))
        } else if decl.type == "record_declaration" {
            supers.append(.unresolved(simpleName: "Record", arguments: []))
        } else if decl.type == "class_declaration" {
            supers.append(objectType)
        } else if decl.type == "annotation_type_declaration" {
            supers.append(annotationType)
        }
        if let list = decl.child(byFieldName: "interfaces")?.firstNamedChild(ofType: "type_list") {
            supers.append(contentsOf: list.namedChildren.map(JavaTypeNodeConverter.convert))
        }
        if let list = decl.firstNamedChild(ofType: "extends_interfaces")?.firstNamedChild(ofType: "type_list") {
            supers.append(contentsOf: list.namedChildren.map(JavaTypeNodeConverter.convert))
        }
        return supers
    }

    private static func lombokImports(in context: JavaInspectionContext) -> (extensionMethods: Bool, any: Bool) {
        var extensionMethods = false
        var any = false
        for imp in context.file.imports {
            let name = imp.qualifiedName
            if name == "lombok.experimental.ExtensionMethod" || name.hasPrefix("lombok.experimental.ExtensionMethod.") {
                extensionMethods = true
            }
            if name == "lombok" || name.hasPrefix("lombok.") { any = true }
        }
        return (extensionMethods, any)
    }

    // MARK: - Per-pass caches

    private static func cachedReceiver(key: String, pass: Pass) -> TypedReceiver? {
        guard let type = pass.receiverTypes[key], let context = pass.receiverContexts[key] else { return nil }
        return TypedReceiver(type: type, context: context)
    }

    private static func storeReceiver(key: String, type: JavaTypeRef?, context: JavaResolutionContext, pass: Pass) -> TypedReceiver? {
        guard let type else {
            pass.unknownReceivers.insert(key)
            return nil
        }
        pass.receiverTypes[key] = type
        pass.receiverContexts[key] = context
        return TypedReceiver(type: type, context: context)
    }
}

private struct TypedReceiver {
    let type: JavaTypeRef
    let context: JavaResolutionContext
}

private struct MemberNames {
    var methods: Set<String>
    var fields: Set<String>
    var nested: Set<String>
}

private struct ImplicitData {
    var methods: Set<String>
    var open: Bool
    var displayName: String?
}

private enum ImplicitScope {
    case named(SyntaxNode)
    case anonymous(body: SyntaxNode, creation: SyntaxNode?)
}

/// One typed pass over a file: receiver types per memo key, member sets per erased
/// class, implicit scopes per innermost body. Used sequentially within the pass.
private final class Pass {
    let context: JavaInspectionContext
    var receiverTypes: [String: JavaTypeRef] = [:]
    var receiverContexts: [String: JavaResolutionContext] = [:]
    var unknownReceivers: Set<String> = []
    var memberSets: [String: MemberNames] = [:]
    var openClasses: Set<String> = []
    var implicitScopes: [Range<Int>: ImplicitData] = [:]
    var resolutions = 0

    init(context: JavaInspectionContext) {
        self.context = context
    }
}
