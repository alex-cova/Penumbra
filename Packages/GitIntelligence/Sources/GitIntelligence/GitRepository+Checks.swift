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
            _ = try await readOnly(["diff", "--cached", "--check"])
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
