import EditorIntelligence
import Foundation

/// Parameter info for Swift calls: every overload of the function or initializer whose argument
/// list holds the caret, with the argument being typed highlighted.
struct SwiftSignatureHelpProvider: SignatureHelpProviding {
    private let index: SwiftIndex

    init(index: SwiftIndex) {
        self.index = index
    }

    func signatureHelp(for document: Document, at position: TextPosition) async -> ParameterHintsModel? {
        guard document.languageIdentifier == SwiftAnalysis.languageIdentifier else { return nil }
        guard let parsed = SwiftAnalysis.parse(document: document) else { return nil }
        if let url = document.url { await index.noteOpenDocument(url: url, text: parsed.text.source) }
        let byte = parsed.text.byteOffset(utf16: position.utf16Offset)
        guard let site = SwiftCallSite.find(parsed: parsed, at: byte) else { return nil }
        let resolver = SwiftResolver(index: index, model: parsed.model, url: document.url)
        let overloads = await resolver.callees(of: site.callee, at: site.calleeStart)
            .filter { $0.declaration.kind != .enumCase || !$0.declaration.parameters.isEmpty }
        guard !overloads.isEmpty else { return nil }

        let sorted = overloads.sorted { $0.declaration.parameters.count < $1.declaration.parameters.count }
        let signatures = sorted.map { Self.signature(of: $0.declaration, owner: $0.owner) }
        let compatible = site.compatible(sorted.map(\.declaration))
        let active = compatible.first.flatMap { chosen in
            sorted.firstIndex { $0.declaration.nameBytes == chosen.nameBytes }
        } ?? 0
        var activeParameter = site.argumentIndex
        if let label = site.currentLabel,
           let found = sorted[active].declaration.parameters.firstIndex(where: { $0.label == label }) {
            activeParameter = found
        }
        return ParameterHintsModel(signatures: signatures, activeSignature: active, activeParameter: activeParameter)
    }

    /// `move(by delta: Int, _ scale: Int = …) -> Point`.
    static func signature(of declaration: SwiftFileModel.Declaration, owner: String?) -> String {
        let parameters = declaration.parameters.map { parameter -> String in
            let label = parameter.label
            let name = parameter.name
            var text: String
            switch (label, name) {
            case (nil, _): text = "_ \(name)"
            case (let label?, _) where label == name: text = name
            case (let label?, _): text = "\(label) \(name)"
            }
            if let type = parameter.typeText ?? parameter.typeName { text += ": \(type)" }
            if parameter.hasDefault { text += " = …" }
            return text
        }
        let name: String
        switch declaration.kind {
        case .initializer: name = owner.map { "\($0).init" } ?? "init"
        case .enumCase: name = owner.map { "\($0).\(declaration.name)" } ?? declaration.name
        default: name = declaration.name
        }
        let returns = declaration.kind == .function ? declaration.typeText.map { " -> \($0)" } ?? "" : ""
        return "\(name)(\(parameters.joined(separator: ", ")))\(returns)"
    }
}
