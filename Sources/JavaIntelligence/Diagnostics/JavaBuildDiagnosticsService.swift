import EditorIntelligence
import Foundation

/// Last-build diagnostics for open files, so a compile paints the editor as well as the
/// Problems list: squiggles, the error stripe and the inspection widget all read the editor's
/// diagnostics, while a finished Gradle or Maven run otherwise only reaches the build bucket.
///
/// The host publishes each finished run's per-file diagnostics (the same map it lists as build
/// problems); this provider serves them back for exactly the text they were mapped against.
/// Entries are keyed by a hash of that text, so an edited file reports the previous text's rows
/// as stale instead of as current — the same contract ``JavaCompilerDiagnosticsService`` keeps.
///
/// Entries never replace live results: they carry their build source (`gradle`, `maven`), and
/// the engine deduplicates rows that live providers restate.
public actor JavaBuildDiagnosticsService: DiagnosticProvider {
    public nonisolated let name = "build"

    private struct Entry {
        /// Hash of the text the diagnostics were mapped against, or `nil` when that text was
        /// unavailable: such rows are always stale.
        let textHash: Int?
        let source: String
        let diagnostics: [Diagnostic]
    }

    private var entries: [URL: Entry] = [:]

    public init() {}

    // MARK: - Publishing (host)

    /// Adopts a finished build's per-file diagnostics, replacing this source's previous ones.
    /// Files with no diagnostics clear their entry: the build says they are clean.
    /// - Parameters:
    ///   - texts: the text each file's diagnostics were mapped against (an open buffer, else the
    ///     file on disk), keyed by file. A file with no text is served as always stale.
    ///   - diagnostics: per-file diagnostics, as listed in the build bucket.
    ///   - source: the build source (`gradle`, `maven`), kept on the served rows.
    public func publish(texts: [URL: String], diagnostics: [URL: [Diagnostic]], source: String) {
        for url in entries.filter({ $0.value.source == source }).map(\.key) {
            entries[url] = nil
        }
        var standardizedTexts: [URL: String] = [:]
        for (url, text) in texts { standardizedTexts[url.standardizedFileURL] = text }
        for (url, list) in diagnostics where !list.isEmpty {
            let key = url.standardizedFileURL
            entries[key] = Entry(textHash: standardizedTexts[key]?.hashValue, source: source, diagnostics: list)
        }
    }

    /// Drops every entry of one build source, e.g. when a new run of it starts.
    public func clear(source: String) {
        for url in entries.filter({ $0.value.source == source }).map(\.key) {
            entries[url] = nil
        }
    }

    /// Drops a file's entries from every build source, e.g. on save (the live check takes over)
    /// or when its build problems are cleared.
    public func clear(url: URL) {
        entries[url.standardizedFileURL] = nil
    }

    /// Drops everything, e.g. when the project changes.
    public func clearAll() {
        entries = [:]
    }

    // MARK: - DiagnosticProvider

    public func diagnostics(for document: Document) async -> [Diagnostic] {
        guard document.languageIdentifier == "java",
              let url = document.url?.standardizedFileURL,
              let entry = entries[url]
        else { return [] }
        return entry.diagnostics
    }

    public func diagnosticsWithFreshness(for document: Document) async -> (diagnostics: [Diagnostic], staleSources: Set<String>) {
        let found = await diagnostics(for: document)
        guard !found.isEmpty,
              let url = document.url?.standardizedFileURL,
              let entry = entries[url]
        else { return (found, []) }
        let fresh = entry.textHash == document.text.hashValue
        return (found, fresh ? [] : [entry.source])
    }
}
