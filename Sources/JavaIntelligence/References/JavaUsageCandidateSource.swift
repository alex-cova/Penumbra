import Foundation

/// Narrows a project to the files that might mention an identifier, so only those are parsed and
/// resolved. The persistent name index conforms; ``JavaTextScanCandidateSource`` is the fallback
/// that needs no index.
public protocol JavaUsageCandidateSource: Sendable {
    /// Files under `roots` (directories, or single files) whose text contains `identifier`.
    func candidateFiles(containing identifier: String, in roots: [URL]) async -> [URL]
}

/// Walks the roots and reads every `.java` file, keeping those containing the identifier as a
/// substring. Slow on a large tree, but always available and always fresh. A file open in an
/// editor is read through `textProvider` (or ``JavaMemberLookup/sourceTextProvider``) so unsaved
/// edits count.
public struct JavaTextScanCandidateSource: JavaUsageCandidateSource {
    private let textProvider: (@Sendable (URL) async -> String?)?
    private let extraFiles: [URL]

    /// - Parameter extraFiles: files to consider even when outside `roots` (unsaved or open buffers).
    public init(textProvider: (@Sendable (URL) async -> String?)? = nil, extraFiles: [URL] = []) {
        self.textProvider = textProvider
        self.extraFiles = extraFiles
    }

    public func candidateFiles(containing identifier: String, in roots: [URL]) async -> [URL] {
        guard !identifier.isEmpty else { return [] }
        let provider = textProvider ?? JavaMemberLookup.sourceTextProvider
        var seen = Set<String>()
        var found: [URL] = []
        for file in javaFiles(in: roots) + extraFiles {
            if Task.isCancelled { break }
            let standardized = file.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { continue }
            var text: String?
            if let provider { text = await provider(standardized) }
            if text == nil { text = try? String(contentsOf: standardized, encoding: .utf8) }
            if let text, text.contains(identifier) { found.append(standardized) }
        }
        return found
    }

    private func javaFiles(in roots: [URL]) -> [URL] {
        var files: [URL] = []
        for root in roots {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else { continue }
            if !isDirectory.boolValue {
                if root.pathExtension == "java" { files.append(root) }
                continue
            }
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in walker where url.pathExtension == "java" {
                files.append(url)
            }
        }
        return files.sorted { $0.path < $1.path }
    }
}
