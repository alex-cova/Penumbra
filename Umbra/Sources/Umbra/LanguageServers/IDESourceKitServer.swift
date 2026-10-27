import EditorIntelligence
import EditorIntelligenceLSP
import Foundation
import SubprocessKit

/// SourceKit-LSP as Swift's semantic tier. Discovery is a user path, then `xcrun --find`, then
/// `/usr/bin/sourcekit-lsp`. The process starts only after the folder is trusted.
enum IDESourceKitServer {
    static let id = "sourcekit-lsp"
    static let pathKey = "umbra.swift.sourcekitPath"

    /// Not `.formatting` and not `.semanticTokens`: the semantic tier outranks the native one while
    /// the server is connected, so claiming them would hand both away from `SwiftFormattingProvider`
    /// and `SwiftSemanticTokenProvider`. The LSP semantic-token provider asks the server about a
    /// document it never opened (`untitled:…`, error -32001), so it can never answer and the colours
    /// freeze; and SourceKit's formatter is swift-format with its own style, not the editor's
    /// indentation settings.
    static let features: Set<LanguageFeature> = [
        .completion, .hover, .signatureHelp, .definition, .implementation, .typeDefinition, .references,
        .rename, .codeActions, .diagnostics, .inlayHints, .structure,
        .typeHierarchy, .callHierarchy
    ]

    static func definition() -> IDELanguageServerDefinition {
        IDELanguageServerDefinition(
            id: id,
            configuration: LSPLanguageConfiguration(
                name: "SourceKit-LSP",
                languageIdentifiers: ["swift"],
                policy: LanguagePolicy(disabling: [.snippets, .duplicateSymbolDiagnostics, .symbolHover, .symbolNavigation]),
                enabledFeatures: features,
                diagnosticSource: .sourceKitLSP
            ),
            isRelevantToProject: isRelevantToProject,
            discover: { await executable(in: $0) },
            initializationOptions: { IDEXcodeIndexDatabase.initializationOptions(for: $0) },
            prepare: { await prepare(root: $0) },
            trustFile: "sourcekit-lsp-trust.json"
        )
    }

    /// A SwiftPM package at the project root (the same signal as ``IDESwiftPMProjectSystem``) or an Xcode
    /// project, whose build settings come from ``IDEXcodeIndexDatabase``.
    static func isRelevantToProject(root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path)
            || IDEXcodeProjectModel.findProject(in: root) != nil
    }

    /// A package needs nothing. An Xcode-only folder needs its compilation database: without it the server
    /// sees one file at a time and, ranked above the native tier, would answer worse than it. A database
    /// left by an earlier run is good enough when the new one cannot be made.
    static func prepare(root: URL) async -> IDEServerPreparation {
        guard IDEXcodeIndexDatabase.isXcodeOnly(root: root) else { return .ready }
        let outcome = await IDEXcodeIndexDatabase.generate(root: root)
        if outcome.isUsable || IDEXcodeIndexDatabase.initializationOptions(for: root) != nil { return .ready }
        switch outcome {
        case .generated: return .ready
        case .unavailable(let reason), .failed(let reason): return .unavailable(reason)
        }
    }

    static func executable(in context: IDEServerDiscoveryContext) async -> IDEServerExecutable? {
        if let override = UserDefaults.standard.string(forKey: pathKey),
           FileManager.default.isExecutableFile(atPath: override) {
            return IDEServerExecutable(url: URL(fileURLWithPath: override), environment: context.environment)
        }
        if let found = await xcrunFind() {
            return IDEServerExecutable(url: URL(fileURLWithPath: found), environment: context.environment)
        }
        let fallback = "/usr/bin/sourcekit-lsp"
        guard FileManager.default.isExecutableFile(atPath: fallback) else { return nil }
        return IDEServerExecutable(url: URL(fileURLWithPath: fallback), environment: context.environment)
    }

    private static func xcrunFind() async -> String? {
        var request = SubprocessRequest(executable: "/usr/bin/xcrun", arguments: ["--find", "sourcekit-lsp"])
        request.stdoutCapture = .bounded(head: 2_048, tail: 0)
        request.stderrCapture = .discard
        guard let result = try? await SubprocessRunner.run(request), result.exit.succeeded else { return nil }
        let path = result.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }
}
