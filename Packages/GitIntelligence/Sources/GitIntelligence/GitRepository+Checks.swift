import Foundation

/// A line `git diff --cached --check` complains about.
public struct GitDiffCheckProblem: Sendable, Equatable {
    public let path: String
    public let line: Int
    public let message: String

    public var isConflictMarker: Bool { message.contains("conflict marker") }

    public init(path: String, line: Int, message: String) {
        self.path = path
        self.line = line
        self.message = message
    }
}

/// How a staged file stores its line endings, as `git ls-files --eol` reports the index side.
public enum GitIndexLineEndings: String, Sendable {
    case lf
    case crlf
    case mixed
    case binary = "-text"
    case none
}

public enum GitDiffCheckParser {
    /// `path:12: leftover conflict marker` / `path:3: trailing whitespace.`
    public static func parse(_ output: String) -> [GitDiffCheckProblem] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let number = Int(parts[1]) else { return nil }
            return GitDiffCheckProblem(
                path: String(parts[0]), line: number,
                message: String(parts[2]).trimmingCharacters(in: .whitespaces))
        }
    }
}

public enum GitEOLParser {
    /// `i/lf    w/lf    attr/                 \tpath` lines.
    public static func parse(_ output: String) -> [String: GitIndexLineEndings] {
        var result: [String: GitIndexLineEndings] = [:]
        for line in output.split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let fields = line[..<tab].split(separator: " ", omittingEmptySubsequences: true)
            guard let index = fields.first(where: { $0.hasPrefix("i/") }) else { continue }
            let path = String(line[line.index(after: tab)...])
            result[path] = GitIndexLineEndings(rawValue: String(index.dropFirst(2))) ?? GitIndexLineEndings.none
        }
        return result
    }
}

/// Facts a host needs before committing: what is wrong with the staged content.
extension GitRepository {
    /// Problems in the staged changes that git itself flags, such as leftover conflict markers.
    public func stagedCheckProblems() async -> [GitDiffCheckProblem] {
        do {
            _ = try await readOnly(["diff", "--no-ext-diff", "--cached", "--check"])
            return []
        } catch GitError.failed(_, _, let stdout) {
            return GitDiffCheckParser.parse(String(decoding: stdout, as: UTF8.self))
        } catch {
            return []
        }
    }

    /// The line endings of `paths` as they are staged.
    public func indexLineEndings(of paths: [String]) async -> [String: GitIndexLineEndings] {
        guard !paths.isEmpty else { return [:] }
        var result: [String: GitIndexLineEndings] = [:]
        for start in stride(from: 0, to: paths.count, by: 200) {
            let chunk = Array(paths[start ..< min(start + 200, paths.count)])
            if let out = try? await readOnly(["--literal-pathspecs", "ls-files", "--eol", "--"] + chunk) {
                result.merge(GitEOLParser.parse(out.text)) { _, new in new }
            }
        }
        return result
    }

    /// Makes `paths` LF in the index and keeps new additions that way (`core.autocrlf=input` for
    /// this repository, then a re-add that applies it).
    public func normalizeLineEndings(of paths: [String]) async throws {
        try await setConfig("core.autocrlf", to: "input")
        guard !paths.isEmpty else { return }
        _ = try await mutate(["--literal-pathspecs", "add", "--renormalize", "--"] + paths)
    }
}

/// A way the repository's own files can make git run a program when the user acts on it.
public struct GitExecutableExposure: Sendable, Equatable, Hashable {
    public enum Kind: String, Sendable { case hook, configuration }

    public let kind: Kind
    /// The hook's file name, or the config key.
    public let name: String

    public init(kind: Kind, name: String) {
        self.kind = kind
        self.name = name
    }
}

extension GitRepository {
    /// The executable hooks and the local config keys that name a program, which git would run on a
    /// commit, a checkout, a stage, a fetch and so on. Reading never runs any of them: the runner
    /// switches fsmonitor off and the patch commands pass `--no-ext-diff --no-textconv`. Empty for
    /// a repository with only git's `.sample` hooks and ordinary settings.
    public func executableExposure() async -> [GitExecutableExposure] {
        var found: [GitExecutableExposure] = []
        if let out = try? await readOnly(["config", "--local", "-z", "--list"]) {
            for record in out.text.split(separator: "\0", omittingEmptySubsequences: true) {
                let parts = record.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(parts[0])
                let value = parts.count > 1 ? String(parts[1]) : ""
                if Self.keyNamesAProgram(key, value: value) { found.append(GitExecutableExposure(kind: .configuration, name: key)) }
            }
        }
        if let out = try? await readOnly(["rev-parse", "--git-path", "hooks"]) {
            let path = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let hooks = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: hooks.path)) ?? []
            for name in names.sorted() where !name.hasSuffix(".sample") && !name.hasPrefix(".") {
                var isDirectory: ObjCBool = false
                let file = hooks.appendingPathComponent(name).path
                guard FileManager.default.fileExists(atPath: file, isDirectory: &isDirectory), !isDirectory.boolValue,
                      FileManager.default.isExecutableFile(atPath: file) else { continue }
                found.append(GitExecutableExposure(kind: .hook, name: name))
            }
        }
        return found
    }

    /// `-c filter.<name>.clean=` (and smudge, process, required) for every filter the repository's own
    /// config defines. `git status` and `git diff` run a file's clean filter to compare it with the
    /// index, so reading an untrusted repository would run the program. With the commands blank git
    /// skips the filter. A repository that really uses one (LFS) may then list changed files that
    /// are not; the host uses this only until the user trusts the repository.
    public func filterOverrides() async -> [String] {
        guard let out = try? await readOnly(["config", "--local", "-z", "--list"]) else { return [] }
        var names = Set<String>()
        for record in out.text.split(separator: "\0", omittingEmptySubsequences: true) {
            let key = String(record.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)[0])
            let lowered = key.lowercased()
            guard lowered.hasPrefix("filter."), let dot = key.lastIndex(of: "."), dot > key.index(key.startIndex, offsetBy: 7) else { continue }
            names.insert(String(key[key.index(key.startIndex, offsetBy: 7)..<dot]))
        }
        return names.sorted().flatMap { name in
            ["clean", "smudge", "process"].flatMap { ["-c", "filter.\(name).\($0)="] } + ["-c", "filter.\(name).required=false"]
        }
    }

    private static let programKeys: Set<String> = [
        "core.fsmonitor", "core.sshcommand", "core.hookspath", "core.editor", "core.pager", "core.askpass",
        "core.gitproxy", "core.alternaterefscommand", "diff.external", "gpg.program", "sequence.editor",
        "credential.helper", "uploadpack.packobjectshook"
    ]

    /// `section.subsection.name` with a subsection that may hold dots. Section and name are
    /// case-insensitive in git, so they are compared lowercased.
    static func keyNamesAProgram(_ key: String, value: String) -> Bool {
        let lowered = key.lowercased()
        if programKeys.contains(lowered) { return true }
        func has(_ section: String, _ names: [String]) -> Bool {
            guard lowered.hasPrefix(section + ".") else { return false }
            return names.contains { lowered.hasSuffix("." + $0) && lowered.count > section.count + $0.count + 1 }
        }
        if has("filter", ["clean", "smudge", "process"]) || has("diff", ["textconv", "command"])
            || has("merge", ["driver"]) || has("mergetool", ["cmd"]) || has("difftool", ["cmd"])
            || has("credential", ["helper"]) || has("gpg", ["program"])
            || has("remote", ["receivepack", "uploadpack", "vcs", "proxy"]) { return true }
        if lowered.hasPrefix("alias."), value.hasPrefix("!") { return true }
        return false
    }
}
