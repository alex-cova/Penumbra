import Foundation

/// Go to Definition from inside a `/** */` comment: `{@link X}`, `{@link X#m(T)}`, `{@link #m}`,
/// `@see X`, `@throws X`, `@param name`.
extension JavaNavigationSession {
    /// Where the session should stand to resolve `#member` references: inside the documented type.
    /// A comment in a class body is already there; one above a top-level type is moved to that
    /// type's body.
    static func javadocAnchor(of comment: SyntaxNode) -> Int {
        guard let parent = comment.parent, parent.type != "class_body", parent.type != "interface_body",
              parent.type != "enum_body", parent.type != "record_declaration_body",
              let declaration = documentedDeclaration(after: comment),
              let body = declaration.child(byFieldName: "body") else { return comment.startByte }
        return body.startByte + 1
    }

    /// The declaration a doc comment belongs to: the first sibling after it that is not a comment.
    static func documentedDeclaration(after comment: SyntaxNode) -> SyntaxNode? {
        guard let parent = comment.parent else { return nil }
        var passed = false
        for child in parent.children {
            if passed, child.type != "block_comment", child.type != "line_comment" { return child }
            if child.byteRange == comment.byteRange { passed = true }
        }
        return nil
    }

    func javadocHits(comment: SyntaxNode, clickOffset: Int) async -> [JavaDefinitionHit] {
        let text = comment.text
        guard text.hasPrefix("/**"),
              let reference = JavadocReferenceScanner.reference(in: text, atByteOffset: clickOffset - comment.startByte) else {
            return []
        }
        switch reference.kind {
        case .parameter(let name):
            guard let declaration = Self.documentedDeclaration(after: comment),
                  let range = JavaDeclarationLocator.parameterRange(named: name, in: declaration) else { return [] }
            return [hit(text: source, url: fileURL, byteRange: range, displayName: name)]
        case .typeParameter(let name):
            guard let declaration = Self.documentedDeclaration(after: comment),
                  let range = JavaDeclarationLocator.typeParameterRange(named: name, in: declaration) else { return [] }
            return [hit(text: source, url: fileURL, byteRange: range, displayName: name)]
        case .type(let components):
            return await javadocTypeHits(components)
        case .member(let owner, let name, let parameterTypes):
            return await javadocMemberHits(owner: owner, name: name, parameterTypes: parameterTypes)
        }
    }

    private func javadocTypeHits(_ components: [String]) async -> [JavaDefinitionHit] {
        if let resolved = await resolveType(components: components), case .classType(let qualifiedName, _, _) = resolved {
            return await typeHits(qualifiedName: qualifiedName)
        }
        return components.count > 1 ? await packageHits(components: components) : []
    }

    private func javadocMemberHits(owner: [String]?, name: String, parameterTypes: [String]?) async -> [JavaDefinitionHit] {
        let type: JavaTypeRef?
        if let owner {
            type = await resolveType(components: owner)
        } else {
            type = context.enclosingTypeQualifiedNames.first.map { .classType(qualifiedName: $0, arguments: [], outer: nil) }
        }
        guard let type, case .classType = type else { return [] }
        var targets = await allMethods(named: name, on: type, mode: .instance)
        if let parameterTypes {
            let matching = targets.filter { JavaTypeKeys.keys(of: $0.method) == parameterTypes }
            if !matching.isEmpty { targets = matching }
        }
        let methods = await methodHits(targets)
        if !methods.isEmpty { return methods }
        return await fieldHits(named: name, on: type, mode: .instance)
    }
}
