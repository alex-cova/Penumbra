import EditorIntelligence
import EditorIntelligenceLSP
import Foundation

/// typescript-language-server as the semantic tier for TypeScript and JavaScript. Discovery is a
/// user path, the project's `node_modules/.bin`, then `PATH`. A folder without Node keeps the
/// native tier.
enum IDETypeScriptServer {
    static let id = "typescript-language-server"
    static let pathKey = "umbra.typescript.serverPath"

    static let features: Set<LanguageFeature> = [
        .completion, .hover, .signatureHelp, .definition, .implementation, .typeDefinition, .references,
        .rename, .codeActions, .formatting, .diagnostics, .semanticTokens, .inlayHints, .structure,
        .callHierarchy
    ]

    static func definition() -> IDELanguageServerDefinition {
        IDELanguageServerDefinition(
            id: id,
            configuration: LSPLanguageConfiguration(
                name: "TypeScript",
                languageIdentifiers: ["typescript", "javascript"],
                lspLanguageID: { url, identifier in
                    switch url?.pathExtension.lowercased() {
                    case "tsx": return "typescriptreact"
                    case "jsx": return "javascriptreact"
                    case "js", "mjs", "cjs": return "javascript"
                    default: return identifier == "javascript" ? "javascript" : "typescript"
                    }
                },
                policy: LanguagePolicy(disabling: [.snippets, .symbolHover, .symbolNavigation]),
                enabledFeatures: features,
                diagnosticSource: .typeScriptLSP
            ),
            isRelevantToProject: isRelevantToProject,
            discover: { context in
                guard let launch = launch(root: context.root) else { return nil }
                return IDEServerExecutable(url: launch.executable, environment: context.environment)
            },
            arguments: { root in launch(root: root)?.arguments ?? ["--stdio"] },
            trustFile: "typescript-language-server-trust.json"
        )
    }

    /// Root `package.json` or a TypeScript/JavaScript config, aligned with ``IDENpmProjectSystem``.
    static func isRelevantToProject(root: URL) -> Bool {
        let names = ["package.json", "tsconfig.json", "jsconfig.json"]
        return names.contains { name in
            FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
        }
    }

    static func launch(root: URL) -> (executable: URL, arguments: [String])? {
        guard isRelevantToProject(root: root) else { return nil }
        if let override = UserDefaults.standard.string(forKey: pathKey),
           FileManager.default.isExecutableFile(atPath: override) {
            return (URL(fileURLWithPath: override), ["--stdio"])
        }
        let local = root.appendingPathComponent("node_modules/.bin/typescript-language-server")
        if FileManager.default.isExecutableFile(atPath: local.path) {
            return (local, ["--stdio"])
        }
        if let onPath = executable(named: "typescript-language-server") {
            return (onPath, ["--stdio"])
        }
        return nil
    }

    /// `node` on `PATH`, else Homebrew's. Used by the status detail when the server itself is missing.
    static func node() -> URL? {
        executable(named: "node") ?? {
            let homebrew = URL(fileURLWithPath: "/opt/homebrew/bin/node")
            return FileManager.default.isExecutableFile(atPath: homebrew.path) ? homebrew : nil
        }()
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
