import EditorIntelligence
import EditorIntelligenceLSP
import Foundation

/// Builds the ``IDELanguageServerDefinition`` of a catalog spec. The host, trust prompt, restart
/// backoff, document sync and status line are the existing ones; nothing here is per language.
enum IDECatalogServer {
    static func definition(for spec: IDELanguageServerSpec) -> IDELanguageServerDefinition {
        let languageIDs = spec.languageIDs
        let lspIDs = spec.lspLanguageIDs
        return IDELanguageServerDefinition(
            id: spec.id,
            configuration: LSPLanguageConfiguration(
                name: spec.displayName,
                languageIdentifiers: Set(languageIDs),
                lspLanguageID: { url, identifier in lspIDs[identifier] ?? identifier },
                // These languages have no native symbol index, so the generic name-based providers stay
                // (word completion before the server answers) but name-matching hover and navigation would
                // contradict the server.
                policy: LanguagePolicy(disabling: [.snippets, .symbolHover, .symbolNavigation]),
                enabledFeatures: spec.features,
                diagnosticSource: spec.diagnosticSource
            ),
            isRelevantToProject: { root in
                isEnabled(spec) && IDEServerProjectProbe.isRelevant(spec, root: root)
            },
            discover: { context in await discover(spec, context: context) },
            arguments: { _ in spec.arguments },
            initializationOptions: { _ in spec.initializationOptions.map { Data($0.utf8) } },
            trustFile: "\(spec.id)-trust.json"
        )
    }

    static func isEnabled(_ spec: IDELanguageServerSpec, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: spec.enabledDefaultsKey) == nil || defaults.bool(forKey: spec.enabledDefaultsKey)
    }

    static func discover(
        _ spec: IDELanguageServerSpec, context: IDEServerDiscoveryContext, defaults: UserDefaults = .standard
    ) async -> IDEServerExecutable? {
        let login = await IDEServerLocator.loginShellPath()
        let processPath = IDEServerLocator.pathEntries(context.environment["PATH"])
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let url = IDEServerLocator.locate(
            spec: spec, root: context.root, override: defaults.string(forKey: spec.pathDefaultsKey),
            searchPath: processPath + login
        ) else { return nil }
        let environment = IDEServerLocator.environment(
            base: context.environment, searchPath: login,
            extraDirectories: spec.extraSearchDirectories.map { IDEServerLocator.expand($0, home: home) }
        )
        return IDEServerExecutable(url: url, environment: environment)
    }
}
