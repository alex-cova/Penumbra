import EditorIntelligence
import EditorIntelligenceLSP
import Foundation

/// One catalog language server, declared as data. ``IDELanguageServerCatalog`` lists them and
/// ``IDECatalogServer`` turns each into an ``IDELanguageServerDefinition``, so a new LSP-backed
/// language is one entry here plus a `LanguageDefinition` for its files, never new completion,
/// diagnostics or document-sync code (that is `EditorIntelligenceLSP`, shared).
struct IDELanguageServerSpec: Sendable, Identifiable {
    /// Stable id: the connection box key, the trust file stem and the defaults-key stem.
    var id: String
    var displayName: String
    /// Umbra language identifiers the server answers for (`c` and `cpp` share `clangd`).
    var languageIDs: [String]
    /// LSP `languageId` per Umbra identifier, when it differs (`shell` is `shellscript`).
    var lspLanguageIDs: [String: String] = [:]
    /// Executable names tried in order.
    var executables: [String]
    var arguments: [String] = []
    /// Arguments that make the binary print its version and exit. Nil when that is not known to be safe
    /// (a launcher that would start the server instead), and Settings then shows no version.
    var versionArguments: [String]? = ["--version"]
    /// Folder markers (`Cargo.toml`, or `*.sln` for a suffix). Any one at the root, or in a direct
    /// child folder (a monorepo), makes the server relevant.
    var projectMarkers: [String]
    /// File extensions that make the server relevant for a folder without a marker (a bounded,
    /// shallow scan). Empty means markers are required.
    var sourceExtensions: [String] = []
    var relevance = Relevance.markerOrSources

    enum Relevance: Sendable {
        /// A marker, or failing that a source file: a folder of loose scripts still gets a server.
        case markerOrSources
        /// Both. Kotlin's Gradle markers are every Java project's, so a marker alone says nothing.
        case markerAndSources
        /// A source file is enough and markers are only hints (clangd works on loose files).
        case sources
    }
    /// Paths under the project root tried before `PATH` (`node_modules/.bin/…`, `vendor/bin/…`).
    var projectLocalPaths: [String] = []
    /// Directories searched after `PATH`. `~` is the home folder.
    var extraSearchDirectories: [String] = []
    /// A runtime or SDK the server needs besides its own binary, shown when it is missing.
    var prerequisite: String?
    /// Supported install commands, shown in Settings. Umbra never runs them for the user.
    var installInstructions: [String]
    var installURL: String
    var licence: String
    var notes: String = ""
    /// JSON sent as `initializationOptions`.
    var initializationOptions: String?
    var diagnosticSource: DiagnosticSourceID
    var features: Set<LanguageFeature> = IDELanguageServerSpec.standardFeatures

    /// What the shared LSP service may ask for. `LSPLanguageService` intersects this with what the server
    /// advertised, so a server without call hierarchy never receives the request. Semantic tokens stay
    /// off for the reason `IDEPythonServer.features` records.
    static let standardFeatures: Set<LanguageFeature> = [
        .completion, .hover, .signatureHelp, .definition, .implementation, .typeDefinition, .references,
        .rename, .codeActions, .formatting, .diagnostics, .structure, .inlayHints, .callHierarchy, .typeHierarchy,
    ]

    var pathDefaultsKey: String { "umbra.languageServers.\(id).path" }
    var enabledDefaultsKey: String { "umbra.languageServers.\(id).enabled" }
}
