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

/// What a server needs from the folder before it can be useful, and whether it got it.
enum IDEServerPreparation: Sendable, Equatable {
    case ready
    /// The server would start but answer worse than the native tier (an Xcode project whose build
    /// settings could not be read leaves it blind to every other file). The host does not launch it.
    case unavailable(String)
}

/// One language server a module knows how to launch. The process stays in Umbra; the
/// ``LSPLanguageService`` only answers while the host's connection box has a client.
struct IDELanguageServerDefinition: Sendable {
    var id: String
    var configuration: LSPLanguageConfiguration
    /// When false for the opened folder, the host does not ask for trust, show status, or launch.
    var isRelevantToProject: @Sendable (URL) -> Bool
    var discover: @Sendable (IDEServerDiscoveryContext) async -> IDEServerExecutable?
    var arguments: @Sendable (URL) -> [String]
    var initializationOptions: @Sendable (URL) -> Data?
    /// Runs after trust and discovery, before the process starts, and again at every restart. It may take
    /// a while (reading an Xcode project's build settings); the status reads "starting" meanwhile.
    var prepare: @Sendable (URL) async -> IDEServerPreparation
    var trustFile: String

    init(
        id: String,
        configuration: LSPLanguageConfiguration,
        isRelevantToProject: @escaping @Sendable (URL) -> Bool = { _ in true },
        discover: @escaping @Sendable (IDEServerDiscoveryContext) async -> IDEServerExecutable?,
        arguments: @escaping @Sendable (URL) -> [String] = { _ in [] },
        initializationOptions: @escaping @Sendable (URL) -> Data? = { _ in nil },
        prepare: @escaping @Sendable (URL) async -> IDEServerPreparation = { _ in .ready },
        trustFile: String
    ) {
        self.id = id
        self.configuration = configuration
        self.isRelevantToProject = isRelevantToProject
        self.discover = discover
        self.arguments = arguments
        self.initializationOptions = initializationOptions
        self.prepare = prepare
        self.trustFile = trustFile
    }
}
