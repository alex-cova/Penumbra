import Foundation

/// Decides, from a bounded look at the folder, whether a catalog server is worth starting. It never walks
/// the whole tree: markers are looked for at the root and in its direct children (a monorepo), source
/// files down to three levels, and both stop at fixed entry counts, so opening a huge folder costs the
/// same as opening a small one.
enum IDEServerProjectProbe {
    static let maxMarkerEntries = 400
    static let maxSourceEntries = 1_500
    static let maxSourceDepth = 3
    private static let skipped: Set<String> = [
        "node_modules", ".git", ".build", "target", "build", "dist", "vendor", "Pods", ".gradle", ".venv", "venv",
    ]

    static func isRelevant(_ spec: IDELanguageServerSpec, root: URL, fileManager: FileManager = .default) -> Bool {
        switch spec.relevance {
        case .markerOrSources:
            return hasMarker(spec, root: root, fileManager: fileManager) || hasSource(spec, root: root, fileManager: fileManager)
        case .markerAndSources:
            return hasMarker(spec, root: root, fileManager: fileManager) && hasSource(spec, root: root, fileManager: fileManager)
        case .sources:
            return hasSource(spec, root: root, fileManager: fileManager)
        }
    }

    static func matches(marker: String, name: String) -> Bool {
        marker.hasPrefix("*") ? name.hasSuffix(marker.dropFirst()) : name == marker
    }

    static func hasMarker(_ spec: IDELanguageServerSpec, root: URL, fileManager: FileManager = .default) -> Bool {
        var visited = 0
        var queue: [(URL, Int)] = [(root, 0)]
        while !queue.isEmpty {
            let (directory, depth) = queue.removeFirst()
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names {
                visited += 1
                if visited > maxMarkerEntries { return false }
                if spec.projectMarkers.contains(where: { matches(marker: $0, name: name) }) { return true }
                if depth == 0, !skipped.contains(name), !name.hasPrefix(".") {
                    var isDirectory: ObjCBool = false
                    let child = directory.appendingPathComponent(name)
                    if fileManager.fileExists(atPath: child.path, isDirectory: &isDirectory), isDirectory.boolValue {
                        queue.append((child, 1))
                    }
                }
            }
        }
        return false
    }

    static func hasSource(_ spec: IDELanguageServerSpec, root: URL, fileManager: FileManager = .default) -> Bool {
        guard !spec.sourceExtensions.isEmpty else { return false }
        let extensions = Set(spec.sourceExtensions)
        var visited = 0
        var queue: [(URL, Int)] = [(root, 0)]
        while !queue.isEmpty {
            let (directory, depth) = queue.removeFirst()
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names {
                visited += 1
                if visited > maxSourceEntries { return false }
                if extensions.contains((name as NSString).pathExtension.lowercased()) { return true }
                if depth < maxSourceDepth, !skipped.contains(name), !name.hasPrefix(".") {
                    var isDirectory: ObjCBool = false
                    let child = directory.appendingPathComponent(name)
                    if fileManager.fileExists(atPath: child.path, isDirectory: &isDirectory), isDirectory.boolValue {
                        queue.append((child, depth + 1))
                    }
                }
            }
        }
        return false
    }
}
