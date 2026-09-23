import EditorIntelligence
import Foundation

/// Parameter info for Java calls: the overloads of the method or constructor whose argument list
/// holds the caret, with the argument being typed highlighted. Shares the completion provider's
/// index and source-set scope.
extension JavaCompletionProvider: SignatureHelpProviding {
    public func signatureHelp(for document: Document, at position: TextPosition) async -> ParameterHintsModel? {
        guard document.languageIdentifier == "java", !document.contentSnapshot.isElided else { return nil }
        if let scope = scope(for: document.url) {
            return await JavaIndex.$queryScope.withValue(scope) {
                await self.signatureHelpInScope(for: document, at: position)
            }
        }
        return await signatureHelpInScope(for: document, at: position)
    }

    private func signatureHelpInScope(for document: Document, at position: TextPosition) async -> ParameterHintsModel? {
        let text = document.text
        let url = document.url ?? URL(fileURLWithPath: "/unsaved/\(document.id).java")
        guard let (tree, fileStubs) = parse(text, url: url) else { return nil }
        let offset = Self.utf8ByteOffset(forUTF16Offset: position.utf16Offset, in: text)
        let context = Self.resolutionContext(in: tree, fileStubs: fileStubs, atByteOffset: offset)
        let locals = await JavaExpressionTyper.resolvingVarLocals(
            JavaLocalScope.locals(in: tree, atByteOffset: offset), context: context, index: javaIndex
        )
        let request = JavaSemanticRequest(source: text, bytes: Array(text.utf8), tree: tree, locals: locals, context: context, index: javaIndex)
        guard let site = await JavaExpectedType.callSite(at: offset, request: request), !site.candidates.isEmpty else { return nil }

        let candidates = site.candidates.sorted { $0.parameters.count < $1.parameters.count }
        let signatures = candidates.map { method -> String in
            let name = site.isConstructor ? site.name : method.name
            let returnPrefix = site.isConstructor ? "" : "\(JavaCompletionItemFactory.display(method.returnType)) "
            return "\(returnPrefix)\(name)\(JavaCompletionItemFactory.parameterList(method))"
        }
        let active = candidates.firstIndex {
            $0.parameters.count > site.argumentIndex || ($0.modifiers.contains(.varargs) && !$0.parameters.isEmpty)
        } ?? 0
        return ParameterHintsModel(signatures: signatures, activeSignature: active, activeParameter: site.argumentIndex)
    }
}
