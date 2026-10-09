import Foundation

// One small dispatcher per single-slot feature of `EditorIntelligenceServices`. Each picks the
// providers of the services claiming the document's language (see `LanguageServiceRegistry` for how
// services that share a language combine) and answers like a provider that has nothing to say when
// no service claims it. They hold no state of their own.

struct RoutedFormatting: FormattingProviding {
    let registry: LanguageServiceRegistry

    private func provider(for document: Document) -> (any FormattingProviding)? {
        registry.services(for: document.languageIdentifier)
            .compactMap(\.providers.formatting)
            .first { $0.supportsFormatting(document) }
    }

    func supportsFormatting(_ document: Document) -> Bool {
        provider(for: document) != nil
    }

    func formatDocument(_ document: Document) async -> [TextEdit] {
        guard let provider = provider(for: document) else { return [] }
        return await provider.formatDocument(document)
    }

    func formatSelection(in document: Document, range: TextRange) async -> [TextEdit] {
        guard let provider = provider(for: document) else { return [] }
        return await provider.formatSelection(in: document, range: range)
    }
}

struct RoutedSignatureHelp: SignatureHelpProviding {
    let registry: LanguageServiceRegistry

    func signatureHelp(for document: Document, at position: TextPosition) async -> ParameterHintsModel? {
        for provider in registry.services(for: document.languageIdentifier).compactMap(\.providers.signatureHelp) {
            if let model = await provider.signatureHelp(for: document, at: position) { return model }
        }
        return nil
    }
}

struct RoutedCodeActions: CodeActionProviding {
    let registry: LanguageServiceRegistry

    func codeActions(for document: Document, at position: TextPosition, diagnostics: [Diagnostic]) async -> [CodeAction] {
        var actions: [CodeAction] = []
        for provider in registry.services(for: document.languageIdentifier).compactMap(\.providers.codeActions) {
            actions += await provider.codeActions(for: document, at: position, diagnostics: diagnostics)
        }
        return actions
    }
}

struct RoutedRename: RenameProviding {
    let registry: LanguageServiceRegistry

    func prepareRename(_ context: NavigationContext) async -> RenameTarget? {
        await registry.owner(of: context.document.languageIdentifier, \.rename)?.prepareRename(context)
    }

    func rename(_ context: NavigationContext, to newName: String) async throws -> RenamePlan {
        guard let provider = registry.owner(of: context.document.languageIdentifier, \.rename) else {
            throw LanguageRoutingError(languageIdentifier: context.document.languageIdentifier, feature: "rename")
        }
        return try await provider.rename(context, to: newName)
    }
}

struct RoutedRefactoring: RefactoringProviding {
    let registry: LanguageServiceRegistry

    func availableRefactorings(_ context: RefactoringContext) async -> [RefactoringDescriptor] {
        guard let provider = registry.owner(of: context.document.languageIdentifier, \.refactoring) else { return [] }
        return await provider.availableRefactorings(context)
    }

    func plan(
        _ id: RefactoringID, context: RefactoringContext, parameters: [String: String]
    ) async throws -> WorkspaceEditPlan {
        guard let provider = registry.owner(of: context.document.languageIdentifier, \.refactoring) else {
            throw LanguageRoutingError(languageIdentifier: context.document.languageIdentifier, feature: "refactoring")
        }
        return try await provider.plan(id, context: context, parameters: parameters)
    }
}

struct RoutedCodeGeneration: CodeGenerationProviding {
    let registry: LanguageServiceRegistry

    func generationMenu(_ context: RefactoringContext) async -> CodeGenerationMenu? {
        await registry.owner(of: context.document.languageIdentifier, \.codeGeneration)?.generationMenu(context)
    }

    func generate(
        _ kind: CodeGenerationKind, fieldNames: [String], context: RefactoringContext
    ) async -> WorkspaceEditPlan {
        guard let provider = registry.owner(of: context.document.languageIdentifier, \.codeGeneration) else {
            return WorkspaceEditPlan(blockingError: "Generate is not available for this language.", title: "Generate")
        }
        return await provider.generate(kind, fieldNames: fieldNames, context: context)
    }
}

struct RoutedBreadcrumbs: BreadcrumbProviding {
    let registry: LanguageServiceRegistry

    func breadcrumbs(for document: Document) async -> [BreadcrumbSegment]? {
        await registry.owner(of: document.languageIdentifier, \.breadcrumbs)?.breadcrumbs(for: document)
    }
}

struct RoutedInlayHints: InlayHintProviding {
    let registry: LanguageServiceRegistry

    func inlayHints(for document: Document, in range: TextRange) async -> [InlayHint] {
        guard let provider = registry.owner(of: document.languageIdentifier, \.inlayHints) else { return [] }
        return await provider.inlayHints(for: document, in: range)
    }
}

struct RoutedCodeVision: CodeVisionProviding {
    let registry: LanguageServiceRegistry

    func codeVisionAnchors(for document: Document) async -> [Int] {
        guard let provider = registry.owner(of: document.languageIdentifier, \.codeVision) else { return [] }
        return await provider.codeVisionAnchors(for: document)
    }

    func codeVision(for document: Document, anchors: [Int]) async -> [CodeVisionLens] {
        guard let provider = registry.owner(of: document.languageIdentifier, \.codeVision) else { return [] }
        return await provider.codeVision(for: document, anchors: anchors)
    }
}
