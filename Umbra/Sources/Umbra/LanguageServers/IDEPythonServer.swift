import EditorIntelligence
import EditorIntelligenceLSP
import Foundation

/// `pylsp` (python-lsp-server) as Python's semantic tier: completion, navigation, rename and
/// diagnostics for the trusted folder. Python has no native index the way Swift and TypeScript
/// do, so without a discovered server its files keep tree-sitter highlighting and the generic
/// word/symbol providers only. Discovery is a user path, the folder's virtualenv, then `PATH`.
enum IDEPythonServer {
    static let id = "pylsp"
    static let pathKey = "umbra.python.serverPath"

    /// What `pylsp` answers. Not `.implementation` or `.typeDefinition`: the server does not
    /// implement those requests. Not `.callHierarchy`, `.typeHierarchy` or `.inlayHints`: it does
    /// not offer them either. Not `.semanticTokens`: the LSP semantic-token provider asks the
    /// server about a document it never opened (`untitled:…`), so it can never answer and the
    /// native colours would freeze (the same reason the TypeScript and SourceKit definitions
    /// exclude it). `.structure` stays, unlike TypeScript: there is no native Python outline for
    /// the server's `documentSymbol` to take over from.
    static let features: Set<LanguageFeature> = [
        .completion, .hover, .signatureHelp, .definition, .references,
        .rename, .codeActions, .formatting, .diagnostics,
        .structure
    ]

    static func definition() -> IDELanguageServerDefinition {
        IDELanguageServerDefinition(
            id: id,
            configuration: LSPLanguageConfiguration(
                name: "Python",
                languageIdentifiers: ["python"],
                policy: LanguagePolicy(disabling: [.snippets, .symbolHover, .symbolNavigation]),
                enabledFeatures: features,
                diagnosticSource: .pythonLSP
            ),
            isRelevantToProject: isRelevantToProject,
            discover: { context in launch(root: context.root).map { IDEServerExecutable(url: $0, environment: context.environment) } },
            trustFile: "pylsp-trust.json"
        )
    }

    /// A Python manifest or lockfile at the root: `pyproject.toml`, `setup.py`, `setup.cfg`,
    /// `requirements.txt` or `Pipfile`. A bare folder of scripts gets no server, the same
    /// discipline as the TypeScript definition.
    static func isRelevantToProject(root: URL) -> Bool {
        let names = ["pyproject.toml", "setup.py", "setup.cfg", "requirements.txt", "Pipfile"]
        return names.contains { name in
            FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
        }
    }

    /// The `pylsp` entry point: an explicit user path, the folder's virtualenv, then `PATH`.
    /// `pylsp` speaks stdio by default, so no arguments are needed. `nil` leaves Python on the
    /// tree-sitter tier; the host does not ask for trust, show status, or launch.
    static func launch(root: URL) -> URL? {
        guard isRelevantToProject(root: root) else { return nil }
        if let override = UserDefaults.standard.string(forKey: pathKey),
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        for venv in ["venv", ".venv"] {
            let local = root.appendingPathComponent(venv).appendingPathComponent("bin/pylsp")
            if FileManager.default.isExecutableFile(atPath: local.path) { return local }
        }
        return executable(named: "pylsp")
    }

    private static func executable(named name: String) -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":") where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
