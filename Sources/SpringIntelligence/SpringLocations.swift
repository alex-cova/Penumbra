import EditorIntelligence
import Foundation

extension SpringSourceLocation {
    /// The place as the editor's navigation wants it (line, column, UTF-16 offset), read from the file on disk.
    /// `nil` when the file cannot be read. Used by the tool window, which opens beans, injection points and imports.
    public func editorLocation(displayName: String, documentID: DocumentID = DocumentID()) -> Location? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Location(documentID: documentID, url: url, range: SpringTextRanges(text: text).range(byteRange), displayName: displayName)
    }
}

/// Maps source files to the module that owns them. Roots are standardised once, longest first, so asking per bean (thousands
/// of times when the tool window builds) is a few string prefix tests, not a URL standardisation per module per call.
public struct SpringModuleResolver: Sendable {
    private let roots: [(prefix: String, id: String)]

    public init(modules: [SpringModuleInfo]) {
        roots = modules.flatMap { m in m.sourceRoots.map { (($0.standardizedFileURL.path + "/"), m.projectPath) } }
            .sorted { $0.0.count > $1.0.count }
            .map { (prefix: $0.0, id: $0.1) }
    }

    /// The module whose source root contains `url`. `url` should be standardised (the indexer's URLs are).
    public func owner(of url: URL) -> String? {
        let path = url.path
        return roots.first { path.hasPrefix($0.prefix) }?.id
    }
}

extension SpringModuleInfo {
    /// The module (project path) whose source roots contain `url`; the longest matching root wins. Prefer
    /// ``SpringModuleResolver`` when asking many times.
    public static func owner(of url: URL, in modules: [SpringModuleInfo]) -> String? {
        SpringModuleResolver(modules: modules).owner(of: url.standardizedFileURL)
    }
}
