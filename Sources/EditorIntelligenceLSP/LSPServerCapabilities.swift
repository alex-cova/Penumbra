import EditorIntelligence
import LanguageServerProtocol

/// Which ``LanguageFeature``s a server advertised in `ServerCapabilities`.
public enum LSPServerCapabilities {
    public static func features(in capabilities: ServerCapabilities) -> Set<LanguageFeature> {
        var features: Set<LanguageFeature> = []
        if capabilities.completionProvider != nil { features.insert(.completion) }
        if enabled(capabilities.hoverProvider) { features.insert(.hover) }
        if capabilities.signatureHelpProvider != nil { features.insert(.signatureHelp) }
        if enabled(capabilities.definitionProvider) { features.insert(.definition) }
        if enabled(capabilities.implementationProvider) { features.insert(.implementation) }
        if enabled(capabilities.typeDefinitionProvider) { features.insert(.typeDefinition) }
        if enabled(capabilities.referencesProvider) { features.insert(.references) }
        if enabled(capabilities.renameProvider) { features.insert(.rename) }
        if enabled(capabilities.codeActionProvider) { features.insert(.codeActions) }
        if enabled(capabilities.documentFormattingProvider) || enabled(capabilities.documentRangeFormattingProvider) {
            features.insert(.formatting)
        }
        if capabilities.diagnosticProvider != nil { features.insert(.diagnostics) }
        if capabilities.semanticTokensProvider != nil { features.insert(.semanticTokens) }
        if enabled(capabilities.inlayHintProvider) { features.insert(.inlayHints) }
        if enabled(capabilities.documentSymbolProvider) { features.insert(.structure) }
        if enabled(capabilities.callHierarchyProvider) { features.insert(.callHierarchy) }
        if enabled(capabilities.typeHierarchyProvider) { features.insert(.typeHierarchy) }
        return features
    }

    public static func resolvesCompletionItems(_ capabilities: ServerCapabilities) -> Bool {
        capabilities.completionProvider?.resolveProvider == true
    }

    public static func supportsWorkspaceSymbols(_ capabilities: ServerCapabilities) -> Bool {
        enabled(capabilities.workspaceSymbolProvider)
    }

    public static func supports(_ feature: LanguageFeature, _ capabilities: ServerCapabilities) -> Bool {
        features(in: capabilities).contains(feature)
    }

    private static func enabled<Options: Sendable>(_ value: TwoTypeOption<Bool, Options>?) -> Bool {
        switch value {
        case .none: return false
        case .optionA(let flag): return flag
        case .optionB: return true
        }
    }

    private static func enabled<Options: Sendable, Registration: Sendable>(
        _ value: ThreeTypeOption<Bool, Options, Registration>?
    ) -> Bool {
        switch value {
        case .none: return false
        case .optionA(let flag): return flag
        case .optionB, .optionC: return true
        }
    }
}
