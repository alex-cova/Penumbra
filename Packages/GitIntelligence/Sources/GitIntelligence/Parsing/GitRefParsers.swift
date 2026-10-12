import Foundation

/// `git remote -v`: `origin\tgit@host:o/r.git (fetch)` and the same with `(push)`.
public enum GitRemoteParser {
    public static func parse(_ output: String) -> [GitRemote] {
        var order: [String] = []
        var fetch: [String: String] = [:]
        var push: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == "\t" })
            guard parts.count == 2 else { continue }
            let name = String(parts[0])
            let rest = parts[1]
            guard let space = rest.lastIndex(of: " ") else { continue }
            let url = String(rest[..<space])
            let kind = rest[rest.index(after: space)...]
            if !order.contains(name) { order.append(name) }
            if kind == "(fetch)" { fetch[name] = url } else if kind == "(push)" { push[name] = url }
        }
        return order.map { GitRemote(name: $0, fetchURL: fetch[$0] ?? push[$0] ?? "", pushURL: push[$0] ?? fetch[$0] ?? "") }
    }
}

/// `for-each-ref --format=<GitBranchParser.format>` over `refs/heads` and `refs/remotes`.
public enum GitBranchParser {
    public static let format = "%(refname)%00%(objectname)%00%(upstream:short)%00%(upstream:track)%00%(committerdate:unix)%00%(HEAD)"

    public static func parse(_ output: String) -> [GitBranch] {
        var branches: [GitBranch] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 6 else { continue }
            let ref = fields[0]
            let kind: GitBranch.Kind
            let name: String
            if ref.hasPrefix("refs/heads/") {
                kind = .local
                name = String(ref.dropFirst("refs/heads/".count))
            } else if ref.hasPrefix("refs/remotes/") {
                kind = .remote
                name = String(ref.dropFirst("refs/remotes/".count))
                if name.hasSuffix("/HEAD") { continue }
            } else {
                continue
            }
            let (ahead, behind, gone) = parseTrack(fields[3])
            branches.append(GitBranch(
                name: name,
                kind: kind,
                hash: fields[1],
                isCurrent: fields[5] == "*",
                upstream: fields[2].isEmpty ? nil : fields[2],
                ahead: ahead,
                behind: behind,
                upstreamIsGone: gone,
                lastCommitDate: Date(timeIntervalSince1970: TimeInterval(fields[4]) ?? 0)
            ))
        }
        return branches
    }

    /// `[ahead 2, behind 1]`, `[ahead 2]`, `[behind 1]`, `[gone]` or empty.
    static func parseTrack(_ text: String) -> (ahead: Int, behind: Int, gone: Bool) {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        if trimmed == "gone" { return (0, 0, true) }
        var ahead = 0, behind = 0
        for part in trimmed.split(separator: ",") {
            let words = part.split(separator: " ")
            guard words.count == 2, let count = Int(words[1]) else { continue }
            if words[0] == "ahead" { ahead = count } else if words[0] == "behind" { behind = count }
        }
        return (ahead, behind, false)
    }
}

/// `for-each-ref refs/tags --format=<GitTagParser.format>`.
public enum GitTagParser {
    /// `%(*objectname)` is the commit an annotated tag points at, empty for a lightweight tag.
    public static let format = "%(refname:short)%00%(objectname)%00%(*objectname)%00%(creatordate:unix)%00%(subject)"

    public static func parse(_ output: String) -> [GitTag] {
        var tags: [GitTag] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 5 else { continue }
            let peeled = fields[2]
            tags.append(GitTag(
                name: fields[0],
                commit: peeled.isEmpty ? fields[1] : peeled,
                isAnnotated: !peeled.isEmpty,
                subject: fields[4],
                date: Date(timeIntervalSince1970: TimeInterval(fields[3]) ?? 0)
            ))
        }
        return tags
    }
}
