import Foundation

/// Per-folder consent for one server, the same shape as the Gradle and npm trust files: a JSON
/// array of folder paths the user has allowed that server to run in.
struct IDELanguageServerTrust: Sendable {
    var directory: URL
    var fileName: String

    func isTrusted(_ root: URL) -> Bool {
        paths().contains(Self.key(root))
    }

    func trust(_ root: URL) {
        var known = paths()
        known.insert(Self.key(root))
        write(known)
    }

    private func paths() -> Set<String> {
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(list)
    }

    private func write(_ paths: Set<String>) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = (try? JSONEncoder().encode(paths.sorted())) ?? Data("[]".utf8)
        try? data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
    }

    private static func key(_ root: URL) -> String {
        root.resolvingSymlinksInPath().path
    }
}
