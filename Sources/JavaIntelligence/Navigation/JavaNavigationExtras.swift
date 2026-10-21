import EditorIntelligence
import Foundation

/// Names Go to Definition resolves that the shared ``JavaReferenceClassifier`` does not know.
///
/// Find Usages, Rename and Hover classify through ``JavaReferenceClassifier`` and have no meaning
/// for these yet, so they live beside it instead of widening ``JavaReference``.
enum JavaNavigationExtra {
    /// The label of a `break` or `continue`.
    case label(SyntaxNode)
    /// The `method_reference` node; the click is on its method name or on `new`.
    case methodReference(SyntaxNode)
    /// The key of `@Annotation(key = value)`.
    case annotationElement(annotation: SyntaxNode, name: SyntaxNode)
    /// A bare constant in a `case` label, which names a member of the switched enum.
    case enumCaseLabel(SyntaxNode)
    /// A package name segment, as the dotted name up to the clicked segment.
    case package(components: [String])
}

enum JavaNavigationExtras {
    static func classify(in tree: JavaSyntaxTree, atByteOffset byteOffset: Int) -> JavaNavigationExtra? {
        let leaf = tree.node(atByteOffset: byteOffset)
        guard leaf.byteRange.contains(byteOffset), let parent = leaf.parent else { return nil }
        if leaf.type == "new", parent.type == "method_reference" {
            return .methodReference(parent)
        }
        guard leaf.type == "identifier" else { return nil }
        return classify(identifier: leaf, parent: parent)
    }

    private static func classify(identifier token: SyntaxNode, parent: SyntaxNode) -> JavaNavigationExtra? {
        if let declaration = ancestor(of: token, type: "package_declaration") {
            return packageReference(token, in: declaration)
        }
        switch parent.type {
        case "break_statement", "continue_statement":
            return .label(token)
        case "method_reference":
            let named = parent.namedChildren
            guard named.count >= 2, named.last?.byteRange == token.byteRange else { return nil }
            return .methodReference(parent)
        case "element_value_pair":
            guard parent.child(byFieldName: "key")?.byteRange == token.byteRange,
                  let annotation = ancestor(of: token, type: "annotation") else { return nil }
            return .annotationElement(annotation: annotation, name: token)
        case "switch_label":
            return .enumCaseLabel(token)
        default:
            return nil
        }
    }

    private static func packageReference(_ token: SyntaxNode, in declaration: SyntaxNode) -> JavaNavigationExtra? {
        guard let path = declaration.namedChildren.first(where: { $0.type == "scoped_identifier" || $0.type == "identifier" }),
              path.byteRange.contains(token.startByte) else { return nil }
        let parts = JavaReferenceClassifier.pathComponents(path)
        guard let index = parts.firstIndex(where: { $0.range == token.byteRange }) else { return nil }
        return .package(components: parts[...index].map(\.name))
    }

    private static func ancestor(of node: SyntaxNode, type: String) -> SyntaxNode? {
        var current = node.parent
        while let next = current {
            if next.type == type { return next }
            current = next.parent
        }
        return nil
    }

    /// `a.b.C` in a method reference's qualifier or a type position, as components.
    static func qualifierComponents(_ node: SyntaxNode) -> [String] {
        switch node.type {
        case "identifier", "type_identifier":
            return [node.text]
        case "field_access":
            guard let object = node.child(byFieldName: "object"), let field = node.child(byFieldName: "field") else { return [] }
            return qualifierComponents(object) + [field.text]
        default:
            return JavaReferenceClassifier.pathComponents(node).map(\.name)
        }
    }
}

extension JavaNavigationSession {
    func resolve(extra: JavaNavigationExtra) async -> [JavaDefinitionHit] {
        switch extra {
        case .label(let token):
            guard let range = scopeDeclarationRange(named: token.text, labels: true) else { return [] }
            return [hit(text: source, url: fileURL, byteRange: range, displayName: token.text)]
        case .methodReference(let reference):
            return await methodReferenceHits(reference)
        case .annotationElement(let annotation, let name):
            return await annotationElementHits(annotation: annotation, name: name)
        case .enumCaseLabel(let token):
            return await enumCaseLabelHits(token)
        case .package(let components):
            return await packageHits(components: components)
        }
    }

    // MARK: - Scope tree

    /// The declaration of a local, parameter, pattern binding or (with `labels`) label in scope at
    /// the click, from the memoized scope tree.
    func scopeDeclarationRange(named name: String, labels: Bool) -> Range<Int>? {
        let url = fileURL ?? Self.placeholderURL
        guard let symbol = tree.scopeTree(for: url).symbol(named: name, atByteOffset: byteOffset) else { return nil }
        switch symbol {
        case .local(_, _, let range, _), .parameter(_, _, let range, _):
            return labels ? nil : range
        case .label(_, _, let range):
            return labels ? range : nil
        default:
            return nil
        }
    }

    // MARK: - Method references

    func methodReferenceHits(_ reference: SyntaxNode) async -> [JavaDefinitionHit] {
        let named = reference.namedChildren
        guard let qualifier = named.first else { return [] }
        if reference.children.contains(where: { $0.type == "new" }) {
            let components = JavaNavigationExtras.qualifierComponents(qualifier)
            guard !components.isEmpty, let resolved = await resolveType(components: components),
                  case .classType(let qualifiedName, _, _) = resolved else { return [] }
            return await allConstructorHits(of: qualifiedName)
        }
        guard named.count >= 2, let nameNode = named.last,
              let separator = reference.children.first(where: { $0.type == "::" }) else { return [] }
        let receiver: JavaReceiverInfo?
        if qualifier.type == "super" {
            guard let enclosing = context.enclosingTypeQualifiedNames.first,
                  let superclass = await JavaMemberLookup.directSuperclass(of: enclosing, context: context, index: index) else { return [] }
            receiver = JavaReceiverInfo(type: superclass, isTypeReference: false)
        } else {
            receiver = await JavaExpressionTyper.receiverInfo(
                source: source, realTree: tree, dotOffset: separator.startByte, context: context, index: index
            )
        }
        guard let receiver else { return [] }
        // `Dog::getName` names an instance method through its type, so both kinds qualify.
        let targets = await allMethods(named: nameNode.text, on: receiver.type, mode: .instance)
        return await methodHits(targets)
    }

    /// Every constructor of a class, for `Foo::new` (the target interface decides which one runs).
    func allConstructorHits(of qualifiedName: String) async -> [JavaDefinitionHit] {
        let type = JavaTypeRef.classType(qualifiedName: qualifiedName, arguments: [], outer: nil)
        let declared = await JavaMemberLookup.constructors(of: type, context: context, index: index)
        if declared.isEmpty { return await typeHits(qualifiedName: qualifiedName) }
        let hits = await methodHits(declared.map { MethodTarget(declaringClass: qualifiedName, method: $0) })
        return hits.isEmpty ? await typeHits(qualifiedName: qualifiedName) : hits
    }

    // MARK: - Annotation elements

    func annotationElementHits(annotation: SyntaxNode, name: SyntaxNode) async -> [JavaDefinitionHit] {
        guard let typeNode = annotation.child(byFieldName: "name") else { return [] }
        let components = JavaReferenceClassifier.pathComponents(typeNode).map(\.name)
        guard let resolved = await resolveType(components: components), case .classType = resolved else { return [] }
        return await methodHits(await allMethods(named: name.text, on: resolved, mode: .instance))
    }

    // MARK: - Enum case labels

    /// `case ADMIN` names a constant of the switched type, not anything in scope. Falls back to the
    /// ordinary bare-name lookup when the selector cannot be typed (a constant `static final`).
    func enumCaseLabelHits(_ token: SyntaxNode) async -> [JavaDefinitionHit] {
        var current = token.parent
        while let node = current, node.type != "switch_expression", node.type != "switch_statement" {
            current = node.parent
        }
        if let switchNode = current, let condition = switchNode.child(byFieldName: "condition") {
            let selector = condition.type == "parenthesized_expression" ? (condition.namedChild(at: 0) ?? condition) : condition
            let locals = await scopeLocals(atByteOffset: switchNode.startByte)
            if let info = await JavaExpressionTyper.typeOfExpression(selector.text, locals: locals, context: context, index: index),
               case .classType = info.type {
                let hits = await fieldHits(named: token.text, on: info.type, mode: .staticOnly)
                if !hits.isEmpty { return hits }
            }
        }
        return await bareNameHits(token.text)
    }
}
