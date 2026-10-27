import CryptoKit
import Foundation

/// `xcodebuild -showBuildSettingsForIndex -json` turned into the compilation database SourceKit-LSP
/// reads for a project that has no `Package.swift`.
///
/// The settings are `{ target: { file: { swiftASTCommandArguments: […], … } } }`, and every file's
/// arguments hold the whole module: its name, all of its source files, the SDK, the target triple and
/// the search paths. That is what lets the server see across files.
///
/// Written out as is, a module of N files would repeat N paths in each of N entries. SourceKit-LSP
/// expands `@response-file` arguments, so each distinct argument list is written once to a response
/// file and each file's entry is `["swiftc", "@that-file"]`: the database grows with the number of
/// files, not their square.
///
/// The file paths are the spelling `xcodebuild` used, and the server finds a file by the spelling the
/// editor opens it under; `/tmp/x` and `/private/tmp/x` are the same file and different keys. Each
/// entry is therefore written under every spelling of the project folder.
enum IDEXcodeIndexSettings {
    struct Database: Equatable {
        /// The bytes of `compile_commands.json`.
        var compileCommands: Data
        /// File name to contents. Written in the folder the entries point at.
        var responseFiles: [String: String]
        /// Source files that have an entry (not counting spellings).
        var fileCount: Int
        var moduleCount: Int
    }

    enum Failure: Error, Equatable {
        /// Not the JSON `-showBuildSettingsForIndex` prints.
        case notIndexSettings
        /// Valid, but no Swift file in it: a project of C, or nothing built from source.
        case noSwiftFiles
    }

    /// - Parameters:
    ///   - responseFileDirectory: where the response files will be written; the entries name them by absolute path.
    ///   - targetOrder: targets whose files win when two targets compile one file (an app before its tests).
    ///     Targets not listed follow, sorted by name.
    static func database(
        from settings: Data, projectRoot: URL, responseFileDirectory: URL, targetOrder: [String] = []
    ) throws -> Database {
        guard let object = try? JSONSerialization.jsonObject(with: settings),
              let targets = object as? [String: Any] else { throw Failure.notIndexSettings }
        let ordered = targetOrder.filter { targets[$0] != nil }
            + targets.keys.filter { !targetOrder.contains($0) }.sorted()
        let rootSpellings = rootSpellings(of: projectRoot)

        var responseFiles: [String: String] = [:]
        var seen: Set<String> = []
        var modules: Set<String> = []
        var entries: [(file: String, response: String)] = []
        var fileCount = 0
        for target in ordered {
            guard let files = targets[target] as? [String: Any] else { continue }
            for path in files.keys.sorted() {
                guard let entry = files[path] as? [String: Any],
                      let arguments = entry["swiftASTCommandArguments"] as? [String], !arguments.isEmpty else { continue }
                let module = (entry["swiftASTModuleName"] as? String) ?? target
                let name = responseFileName(module: module, arguments: arguments)
                responseFiles[name] = arguments.map(quoted).joined(separator: "\n") + "\n"
                modules.insert(module)
                var isNew = false
                for spelling in spellings(of: path, rootSpellings: rootSpellings) where seen.insert(spelling).inserted {
                    entries.append((spelling, name))
                    isNew = true
                }
                if isNew { fileCount += 1 }
            }
        }
        guard !entries.isEmpty else { throw Failure.noSwiftFiles }

        let directory = projectRoot.standardizedFileURL.path
        let commands: [[String: Any]] = entries.sorted { $0.file < $1.file }.map { entry in
            [
                "directory": directory,
                "file": entry.file,
                "arguments": ["swiftc", "@" + responseFileDirectory.appendingPathComponent(entry.response).path],
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: commands, options: [.sortedKeys, .withoutEscapingSlashes])
        return Database(compileCommands: data, responseFiles: responseFiles, fileCount: fileCount, moduleCount: modules.count)
    }

    // MARK: - Paths

    /// Every way the project folder can be written: as given, standardized (Foundation turns `/private/tmp`
    /// into `/tmp`) and with every symlink resolved by the system (`/tmp` into `/private/tmp`).
    /// `resolvingSymlinksInPath()` is no help for the last: it strips `/private` as well.
    static func rootSpellings(of root: URL) -> [String] {
        var candidates: [String] = [root.path, root.standardizedFileURL.path]
        if let real = realPath(root.path) { candidates.append(real) }
        var spellings: [String] = []
        for path in candidates where !spellings.contains(path) { spellings.append(path) }
        return spellings
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// `path` as written, then the same file under each other spelling of the folder it is in.
    static func spellings(of path: String, rootSpellings: [String]) -> [String] {
        var result = [path]
        for from in rootSpellings where path == from || path.hasPrefix(from + "/") {
            for to in rootSpellings where to != from {
                let rebased = to + path.dropFirst(from.count)
                if !result.contains(rebased) { result.append(rebased) }
            }
        }
        return result
    }

    /// `directory` as a path relative to `root`, climbing out with `..` where it has to. SourceKit-LSP
    /// ignores an absolute search path outside the workspace and follows a relative one.
    ///
    /// Purely lexical on the paths it is given, because the caller passes real (symlink-resolved) ones:
    /// `standardizedFileURL` would turn `/private/var/…` back into `/var/…` and count one level short.
    static func relativePath(from root: URL, to directory: URL) -> String {
        let from = components(of: root.path)
        let to = components(of: directory.path)
        var shared = 0
        while shared < from.count, shared < to.count, from[shared] == to[shared] { shared += 1 }
        let parts = Array(repeating: "..", count: from.count - shared) + to[shared...]
        return parts.joined(separator: "/")
    }

    private static func components(of path: String) -> [String] {
        var result: [String] = []
        for part in path.split(separator: "/") where part != "." {
            if part == ".." { _ = result.popLast() } else { result.append(String(part)) }
        }
        return result
    }

    // MARK: - Response files

    /// `<module>-<12 hex digits of the arguments' SHA-256>.rsp`: the same arguments always name the same file.
    static func responseFileName(module: String, arguments: [String]) -> String {
        let digest = SHA256.hash(data: Data(arguments.joined(separator: "\n").utf8))
        let hex = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        let safe = String(module.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" })
        return "\(safe)-\(hex).rsp"
    }

    /// One argument as a response file reads it: quoted, with `\` and `"` escaped.
    static func quoted(_ argument: String) -> String {
        "\"" + argument.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
