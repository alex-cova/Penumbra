import EditorIntelligence
import Foundation
import JavaIntelligence

/// Hover shows a declaration's signature and its `///` comment, a local's written or inferred type,
/// and the signature of the few standard-library members the table covers.
struct SwiftHoverProvider: HoverProvider {
    let name = SwiftAnalysis.providerName
    private let index: SwiftIndex

    init(index: SwiftIndex) {
        self.index = index
    }

    func provide(context: HoverContext) async -> HoverResult? {
        guard context.document.languageIdentifier == SwiftAnalysis.languageIdentifier else { return nil }
        guard let parsed = SwiftAnalysis.parse(document: context.document) else { return nil }
        if let url = context.document.url { await index.noteOpenDocument(url: url, text: parsed.text.source) }
        let byte = parsed.text.byteOffset(utf16: context.cursor.position.utf16Offset)
        guard let node = SwiftNames.name(atByte: byte, in: parsed.tree), !SwiftNames.inCommentOrString(node) else { return nil }
        let resolver = SwiftResolver(index: index, model: parsed.model, url: context.document.url)
        var expected: String?
        if let use = parsed.model.use(at: node.byteRange), case .implicitMember = use.role {
            expected = await SwiftExpectedType.find(at: node.startByte, parsed: parsed, resolver: resolver)
        }
        guard let text = await signature(for: node, parsed: parsed, resolver: resolver, expected: expected),
              !text.code.isEmpty else { return nil }
        var contents = "```swift\n\(text.code)\n```"
        if let doc = text.doc, !doc.isEmpty { contents += "\n\n" + doc }
        return HoverResult(contents: contents, range: parsed.text.range(bytes: node.byteRange), source: name)
    }

    private func signature(
        for node: SyntaxNode, parsed: SwiftParsed, resolver: SwiftResolver, expected: String?
    ) async -> (code: String, doc: String?)? {
        if let target = await resolver.target(forNameAt: node.byteRange, expected: expected) {
            switch target {
            case .binding(let binding):
                return (await bindingText(binding, resolver: resolver), nil)
            case .declaration(_, let declaration, let owner):
                var code = declaration.signature
                if declaration.kind == .property, declaration.typeName == nil, let chain = declaration.valueChain,
                   let type = await resolver.typeName(of: chain, at: declaration.fullBytes.lowerBound) {
                    code += "  // \(type)"
                }
                if let owner, !owner.isEmpty, !declaration.isTopLevel, declaration.kind != .extension {
                    code = "// \(owner)\n" + code
                }
                return (code, declaration.docComment)
            case .module(let module):
                return ("import \(module)", nil)
            }
        }
        // A member of a standard-library type the table covers.
        if let use = parsed.model.use(at: node.byteRange), case .member(let chain) = use.role,
           let value = await resolver.value(of: chain, at: use.bytes.lowerBound), case .instance(let type) = value,
           let member = SwiftStandardLibrary.members(ofType: SwiftTypeNames.unwrappedOptional(type)).first(where: { $0.name == use.name }) {
            return (member.signature, nil)
        }
        return nil
    }

    private func bindingText(_ binding: SwiftFileModel.Binding, resolver: SwiftResolver) async -> String {
        switch binding.symbolKind {
        case .function, .type:
            return binding.signature ?? binding.name
        case .parameter, .local:
            var type = binding.typeText ?? binding.typeName
            if type == nil {
                let chain = SwiftChain(base: .name(binding.name, at: binding.scopeStart), steps: [])
                type = await resolver.typeName(of: chain, at: binding.scopeStart)
            }
            let suffix = type.map { ": \($0)" } ?? ""
            if binding.symbolKind == .parameter { return "\(binding.name)\(suffix)  // parameter" }
            return "\(binding.isConstant ? "let" : "var") \(binding.name)\(suffix)"
        }
    }
}
