import Foundation

/// `git status --porcelain=v1 -z`.
public enum GitStatusParser {
    public static func parse(_ porcelain: String) -> [GitStatusEntry] {
        let records = porcelain.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var entries: [GitStatusEntry] = []
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            guard record.count > 3 else { continue }
            let chars = Array(record.prefix(2))
            let path = String(record.dropFirst(3))
            var original: String?
            if chars.contains("R") || chars.contains("C") {
                if index < records.count { original = records[index] }
                index += 1
            }
            entries.append(GitStatusEntry(path: path, originalPath: original, indexCode: chars[0], worktreeCode: chars[1]))
        }
        return entries
    }
}

/// `%D` decorations, e.g. `HEAD -> main, origin/main, tag: v1`.
public enum GitRefParser {
    public static func parse(_ decoration: String, remotes: Set<String> = ["origin", "upstream"]) -> [GitRef] {
        var refs: [GitRef] = []
        for part in decoration.split(separator: ",") {
            var item = part.trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty else { continue }
            if item.hasPrefix("HEAD -> ") {
                refs.append(GitRef(name: "HEAD", kind: .head))
                item = String(item.dropFirst("HEAD -> ".count))
                refs.append(GitRef(name: item, kind: .localBranch))
            } else if item == "HEAD" {
                refs.append(GitRef(name: "HEAD", kind: .head))
            } else if item.hasPrefix("tag: ") {
                refs.append(GitRef(name: String(item.dropFirst(5)), kind: .tag))
            } else if let slash = item.firstIndex(of: "/"), remotes.contains(String(item[..<slash])) {
                refs.append(GitRef(name: item, kind: .remoteBranch))
            } else {
                refs.append(GitRef(name: item, kind: .localBranch))
            }
        }
        return refs
    }
}

/// Output of `git log --format=<GitLogParser.format>`.
public enum GitLogParser {
    public static let format = "%H%x00%P%x00%an%x00%ae%x00%at%x00%D%x00%s%x1e"

    public static func parse(_ output: String, remotes: Set<String> = ["origin", "upstream"]) -> [GitCommit] {
        var commits: [GitCommit] = []
        for record in output.split(separator: "\u{1e}", omittingEmptySubsequences: true) {
            let fields = record.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 7 else { continue }
            let hash = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard hash.count >= 7 else { continue }
            commits.append(GitCommit(
                hash: hash,
                parents: fields[1].split(separator: " ").map(String.init),
                author: fields[2],
                email: fields[3],
                date: Date(timeIntervalSince1970: TimeInterval(fields[4]) ?? 0),
                refs: GitRefParser.parse(fields[5], remotes: remotes),
                subject: fields[6]
            ))
        }
        return commits
    }
}

/// `git diff-tree -r -M --name-status -z`.
public enum GitNameStatusParser {
    public static func parse(_ output: String) -> [GitChangedFile] {
        let tokens = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var files: [GitChangedFile] = []
        var index = 0
        while index < tokens.count {
            let code = tokens[index]
            index += 1
            guard let letter = code.first else { continue }
            if letter == "R" || letter == "C" {
                guard index + 1 < tokens.count else { break }
                files.append(GitChangedFile(status: letter, path: tokens[index + 1], oldPath: tokens[index]))
                index += 2
            } else {
                guard index < tokens.count else { break }
                files.append(GitChangedFile(status: letter, path: tokens[index], oldPath: nil))
                index += 1
            }
        }
        return files
    }
}

/// `git blame --porcelain`. Commit details appear only the first time a commit is seen, so they
/// are cached by hash. The result is indexed by final line (0-based).
public enum GitBlameParser {
    public static func parse(_ output: String) -> [GitBlameLine] {
        struct Info { var author = ""; var time: TimeInterval = 0; var summary = "" }
        var cache: [String: Info] = [:]
        var lines: [GitBlameLine] = []
        var currentHash: String?
        var currentFinalLine = 0
        var pending = Info()

        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if raw.hasPrefix("\t") {
                guard let hash = currentHash else { continue }
                if cache[hash] == nil { cache[hash] = pending }
                let info = cache[hash] ?? pending
                let entry = GitBlameLine(
                    hash: hash,
                    author: info.author,
                    date: Date(timeIntervalSince1970: info.time),
                    summary: info.summary,
                    isUncommitted: hash.allSatisfy { $0 == "0" }
                )
                while lines.count < currentFinalLine - 1 { lines.append(entry) }
                if lines.count == currentFinalLine - 1 { lines.append(entry) }
                currentHash = nil
                continue
            }
            if currentHash == nil {
                let parts = raw.split(separator: " ")
                if parts.count >= 3, parts[0].count >= 40, parts[0].allSatisfy(\.isHexDigit), let final = Int(parts[2]) {
                    currentHash = String(parts[0])
                    currentFinalLine = final
                    pending = cache[String(parts[0])] ?? Info()
                }
                continue
            }
            if raw.hasPrefix("author ") {
                pending.author = String(raw.dropFirst(7))
            } else if raw.hasPrefix("author-time ") {
                pending.time = TimeInterval(raw.dropFirst(12)) ?? 0
            } else if raw.hasPrefix("summary ") {
                pending.summary = String(raw.dropFirst(8))
            }
        }
        return lines
    }
}
