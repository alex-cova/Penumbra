import EditorIntelligence
import EditorIntelligenceLSP
import Foundation

/// Where a discovered server binary lives, and any environment it needs (a toolchain's `PATH`).
struct IDEServerExecutable: Sendable {
    var url: URL
    var environment: [String: String]?

    init(url: URL, environment: [String: String]? = nil) {
        self.url = url
        self.environment = environment
    }
}

/// What ``IDELanguageServerDefinition/discover`` may look at. The host fills it when a folder opens.
struct IDEServerDiscoveryContext: Sendable {
    var root: URL
    var environment: [String: String]
}

/// One language server a module knows how to launch. The process stays in Umbra; the
/// ``LSPLanguageService`` only answers while the host's connection box has a client.
struct IDELanguageServerDefinition: Sendable {
    var id: String
    var configuration: LSPLanguageConfiguration
    var discover: @Sendable (IDEServerDiscoveryContext) async -> IDEServerExecutable?
    var arguments: @Sendable (URL) -> [String]
    var initializationOptions: @Sendable (URL) -> Data?
    var trustFile: String

    init(
        id: String,
        configuration: LSPLanguageConfiguration,
        discover: @escaping @Sendable (IDEServerDiscoveryContext) async -> IDEServerExecutable?,
        arguments: @escaping @Sendable (URL) -> [String] = { _ in [] },
        initializationOptions: @escaping @Sendable (URL) -> Data? = { _ in nil },
        trustFile: String
    ) {
        self.id = id
        self.configuration = configuration
        self.discover = discover
        self.arguments = arguments
        self.initializationOptions = initializationOptions
        self.trustFile = trustFile
    }
}
