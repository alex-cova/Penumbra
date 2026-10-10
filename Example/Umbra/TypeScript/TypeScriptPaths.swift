import Foundation

/// Path rules shared by the index and auto-import. Relative specifiers only: a package name
/// (`react`) is not a file in this project.
enum TypeScriptPaths {
    static let extensions: Set<String> = ["ts", "tsx", "mts", "cts"]
    static let skipDirectories: Set<String> = ["node_modules", "dist", "build", "coverage", ".git", ".next", "out"]
    static let maxBytes = 1_048_576

    static func isSourceFile(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    static func isSkipped(_ url: URL) -> Bool {
        url.standardizedFileURL.pathComponents.contains { skipDirectories.contains($0) }
    }

    /// `./foo`, `../bar`, optional extension already stripped, trailing `index` dropped.
    /// Nil when `target` is `file` itself.
    static func relativeSpecifier(from file: URL, to target: URL) -> String? {
        let from = file.standardizedFileURL
        let target = target.standardizedFileURL
        if from == target { return nil }
        var toPath = target.path
        if extensions.contains(target.pathExtension.lowercased()) {
            toPath = (toPath as NSString).deletingPathExtension
        }
        if (toPath as NSString).lastPathComponent == "index" {
            let parent = (toPath as NSString).deletingLastPathComponent
            if parent != "/" && parent != toPath { toPath = parent }
        }
        let fromParts = from.deletingLastPathComponent().path.split(separator: "/").map(String.init)
        let toParts = toPath.split(separator: "/").map(String.init)
        var index = 0
        while index < fromParts.count && index < toParts.count && fromParts[index] == toParts[index] {
            index += 1
        }
        let ups = Array(repeating: "..", count: fromParts.count - index)
        var relative = (ups + toParts[index...]).joined(separator: "/")
        if relative.isEmpty { relative = "." }
        if !relative.hasPrefix(".") { relative = "./" + relative }
        return relative
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "'", with: "\\'")
    }
}
