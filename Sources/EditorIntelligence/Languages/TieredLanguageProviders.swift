import Foundation

/// Completion for one language. The syntactic tier is yielded first with `isFinished: false` when a
/// higher tier is also ready; the semantic tier then replaces that batch under this provider's name.
/// ``CompletionEngine`` stores items by provider name, so the second snapshot replaces the first.
struct TieredCompletionProvider: CompletionProvider {
    let name: String
    let languageIdentifier: String
    let services: [any LanguageService]

    func isPrimary(for context: CompletionContext) -> Bool {
        guard context.document.languageIdentifier == languageIdentifier else { return false }
        return ready(for: .completion).contains { service in
            service.providers.completion.contains { $0.isPrimary(for: context) }
        }
    }

    func provideUpdates(context: CompletionContext) -> AsyncStream<CompletionUpdate> {
        AsyncStream { continuation in
            let task = Task {
                defer { continuation.finish() }
                guard context.document.languageIdentifier == languageIdentifier else {
                    continuation.yield(CompletionUpdate(items: [], isFinished: true))
                    return
                }
                let groups = TieredGroups.ascending(services, feature: .completion) { !$0.completion.isEmpty }
                guard let highest = groups.last else {
                    continuation.yield(CompletionUpdate(items: [], isFinished: true))
                    return
                }
                if groups.count == 1 {
                    let items = await items(from: highest, context: context)
                    if Task.isCancelled { return }
                    continuation.yield(CompletionUpdate(items: items, isFinished: true))
                    return
                }
                var fast: [CompletionItem] = []
                for group in groups.dropLast() {
                    fast.append(contentsOf: await items(from: group, context: context))
                    if Task.isCancelled { return }
                }
                continuation.yield(CompletionUpdate(items: fast, isFinished: false))
                let semantic = await items(from: highest, context: context)
                if Task.isCancelled { return }
                continuation.yield(CompletionUpdate(items: semantic, isFinished: true))
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func provide(context: CompletionContext) async -> [CompletionItem] {
        var items: [CompletionItem] = []
        for await update in provideUpdates(context: context) {
            items = update.items
        }
        return items
    }

    private func ready(for feature: LanguageFeature) -> [any LanguageService] {
        services.filter { !$0.unavailableFeatures.contains(feature) }
    }

    private func items(from group: [any LanguageService], context: CompletionContext) async -> [CompletionItem] {
        var collected: [CompletionItem] = []
        for service in group {
            for provider in service.providers.completion {
                let batch = await provider.provide(context: context)
                collected.append(contentsOf: batch.map { $0.retaggingSource(name) })
            }
        }
        return collected
    }
}

/// Hover for one language. The highest ready tier is asked first. A nil answer falls through to the
/// next tier, so a server that has nothing to say does not hide the native hover.
struct TieredHoverProvider: HoverProvider {
    let name: String
    let languageIdentifier: String
    let services: [any LanguageService]

    func provide(context: HoverContext) async -> HoverResult? {
        guard context.document.languageIdentifier == languageIdentifier else { return nil }
        let groups = TieredGroups.descending(services, feature: .hover) { !$0.hover.isEmpty }
        for group in groups {
            for service in group {
                for provider in service.providers.hover {
                    if let result = await provider.provide(context: context) { return result }
                }
            }
        }
        return nil
    }
}

/// Diagnostics for one language. Every ready tier contributes. ``DiagnosticEngine`` drops duplicates
/// that share a severity, message and range.
struct TieredDiagnosticProvider: DiagnosticProvider {
    let name: String
    let languageIdentifier: String
    let services: [any LanguageService]

    func diagnostics(for document: Document) async -> [Diagnostic] {
        guard document.languageIdentifier == languageIdentifier else { return [] }
        let groups = TieredGroups.ascending(services, feature: .diagnostics) { !$0.diagnostics.isEmpty }
        var collected: [Diagnostic] = []
        for group in groups {
            for service in group {
                for provider in service.providers.diagnostics {
                    collected.append(contentsOf: await provider.diagnostics(for: document))
                }
            }
        }
        return collected
    }

    func diagnosticsWithFreshness(for document: Document) async -> (diagnostics: [Diagnostic], staleSources: Set<String>) {
        guard document.languageIdentifier == languageIdentifier else { return ([], []) }
        let groups = TieredGroups.ascending(services, feature: .diagnostics) { !$0.diagnostics.isEmpty }
        var collected: [Diagnostic] = []
        var stale: Set<String> = []
        for group in groups {
            for service in group {
                for provider in service.providers.diagnostics {
                    let result = await provider.diagnosticsWithFreshness(for: document)
                    collected.append(contentsOf: result.diagnostics)
                    stale.formUnion(result.staleSources)
                }
            }
        }
        return (collected, stale)
    }
}

/// Navigation for one language. The kind selects the feature whose readiness is checked. The top
/// ready tier is asked first and a nil answer falls through.
struct TieredNavigationProvider: NavigationProvider {
    let name: String
    let languageIdentifier: String
    let services: [any LanguageService]

    func isPrimary(for context: NavigationContext) -> Bool {
        guard context.document.languageIdentifier == languageIdentifier else { return false }
        let feature = TieredGroups.feature(for: context.kind)
        return services.contains { service in
            !service.unavailableFeatures.contains(feature)
                && service.providers.navigation.contains { $0.isPrimary(for: context) }
        }
    }

    func provide(context: NavigationContext) async -> NavigationResult? {
        guard context.document.languageIdentifier == languageIdentifier else { return nil }
        let feature = TieredGroups.feature(for: context.kind)
        let groups = TieredGroups.descending(services, feature: feature) { !$0.navigation.isEmpty }
        for group in groups {
            for service in group {
                for provider in service.providers.navigation {
                    if let result = await provider.provide(context: context) { return result }
                }
            }
        }
        return nil
    }
}

enum TieredGroups {
    static func feature(for kind: NavigationKind) -> LanguageFeature {
        switch kind {
        case .definition: return .definition
        case .implementation: return .implementation
        case .superMethod, .siblings: return .superMethod
        case .typeDefinition: return .typeDefinition
        case .references: return .references
        }
    }

    /// Ready services grouped by tier, lowest tier first. Within a tier, registration order.
    static func ascending(
        _ services: [any LanguageService],
        feature: LanguageFeature,
        hasProvider: (LanguageProviders) -> Bool
    ) -> [[any LanguageService]] {
        grouped(services, feature: feature, hasProvider: hasProvider).sorted { $0.key < $1.key }.map(\.value)
    }

    /// Ready services grouped by tier, highest tier first.
    static func descending(
        _ services: [any LanguageService],
        feature: LanguageFeature,
        hasProvider: (LanguageProviders) -> Bool
    ) -> [[any LanguageService]] {
        grouped(services, feature: feature, hasProvider: hasProvider).sorted { $0.key > $1.key }.map(\.value)
    }

    private static func grouped(
        _ services: [any LanguageService],
        feature: LanguageFeature,
        hasProvider: (LanguageProviders) -> Bool
    ) -> [LanguageServiceTier: [any LanguageService]] {
        var groups: [LanguageServiceTier: [any LanguageService]] = [:]
        for service in services where hasProvider(service.providers) && !service.unavailableFeatures.contains(feature) {
            groups[service.tier, default: []].append(service)
        }
        return groups
    }
}

private extension CompletionItem {
    /// The engine treats an item as primary only when `source` equals the provider's name.
    func retaggingSource(_ source: String) -> CompletionItem {
        CompletionItem(
            id: id, label: label, insertText: insertText, kind: kind, range: range, source: source,
            documentation: documentation, sortText: sortText, filterText: filterText, detail: detail,
            labelDetail: labelDetail, isDeprecated: isDeprecated, insertTextIsSnippet: insertTextIsSnippet,
            additionalEdits: additionalEdits, priority: priority, caretOffset: caretOffset,
            triggersSignatureHelp: triggersSignatureHelp, preselect: preselect,
            allowsAutoInsert: allowsAutoInsert, origin: origin
        )
    }
}
