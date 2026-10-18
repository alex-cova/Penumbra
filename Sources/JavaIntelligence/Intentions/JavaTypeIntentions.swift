import Foundation

/// `var` and an explicit local type. Replacing `var` types the initializer; noticing one does not.
enum JavaTypeIntentions {
    static func explicitToVar(for node: SyntaxNode, options: JavaIntentionOptions, source: String) -> [JavaIntentionOffer] {
        guard options.isEnabled(.explicitToVar), let offer = explicitOffer(for: node, source: source) else { return [] }
        return [offer]
    }

    /// The caret is on a `var` local whose type would be filled in when the menu opens.
    static func noticesVar(for node: SyntaxNode, options: JavaIntentionOptions) -> Bool {
        guard options.isEnabled(.varToExplicit), node.type == "local_variable_declaration", !node.hasError,
              node.child(byFieldName: "type")?.text == "var",
              node.namedChildren(ofType: "variable_declarator").count == 1,
              let declarator = node.firstNamedChild(ofType: "variable_declarator") else { return false }
        return declarator.child(byFieldName: "value") != nil
    }

    static func varToExplicit(
        for node: SyntaxNode, options: JavaIntentionOptions, source: String, index: JavaIndex, fileURL: URL?
    ) async -> JavaIntentionOffer? {
        guard noticesVar(for: node, options: options),
              let type = node.child(byFieldName: "type"),
              let declarator = node.firstNamedChild(ofType: "variable_declarator"),
              let name = declarator.child(byFieldName: "name") else { return nil }
        let scope = scopeOffset(for: node)
        let session = JavaNavigationSession(
            source: source, fileURL: fileURL, tree: node.tree, byteOffset: scope,
            index: index, jdkHome: nil, cacheRoot: FileManager.default.temporaryDirectory,
            openBuffer: nil, decompile: JavaDecompileGate(policy: .denied)
        )
        let locals = await JavaExpressionTyper.resolvingVarLocals(
            JavaLocalScope.locals(in: node.tree, atByteOffset: scope),
            context: session.context, index: index
        )
        guard let local = locals.first(where: { $0.name == name.text }), !local.isVarDeclaration,
              isInformative(local.type) else { return nil }
        let written = JavaSignatureText.text(of: local.type)
        guard written != "var", !written.isEmpty else { return nil }
        return JavaIntentionEdit.offer(
            .varToExplicit, title: "Replace 'var' with '\(written)'",
            replacing: type.byteRange, with: written, in: node.tree, source: source
        )
    }

    private static func explicitOffer(for node: SyntaxNode, source: String) -> JavaIntentionOffer? {
        guard node.type == "local_variable_declaration", !node.hasError,
              let type = node.child(byFieldName: "type"), type.text != "var",
              node.namedChildren(ofType: "variable_declarator").count == 1,
              let declarator = node.firstNamedChild(ofType: "variable_declarator"),
              let value = declarator.child(byFieldName: "value"),
              value.type != "array_initializer", value.type != "lambda_expression", value.type != "method_reference",
              !value.text.contains("<>") else { return nil }
        return JavaIntentionEdit.offer(.explicitToVar, replacing: type.byteRange, with: "var", in: node.tree, source: source)
    }

    /// `Object` is what a failed inference falls back to, so it is not written in place of `var`.
    private static func isInformative(_ type: JavaTypeRef) -> Bool {
        if case .unresolved(let name, _) = type { return name != "Object" && name != "var" && !name.isEmpty }
        return type.simpleDisplayName != "Object"
    }

    /// An offset at which the locals include this declaration.
    private static func scopeOffset(for declaration: SyntaxNode) -> Int {
        if let parent = declaration.parent, parent.type == "block" || parent.type == "constructor_body" {
            return max(parent.endByte - 1, parent.startByte)
        }
        return declaration.endByte
    }
}
