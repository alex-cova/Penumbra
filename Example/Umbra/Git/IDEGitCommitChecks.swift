import Foundation

/// How the next commit is made, from the Changes panel's options.
struct IDEGitCommitOptions: Equatable, Sendable {
    var amend = false
    var signoff = false
    var skipHooks = false
    /// Open the push dialog once the commit is made (Commit and Push…).
    var pushAfter = false
}

/// What the checks look at, gathered from git and the disk before a commit.
struct IDEGitCommitFacts: Equatable, Sendable {
    struct LargeFile: Equatable, Sendable {
        let path: String
        let bytes: Int
    }

    var hasUserName = true
    var hasUserEmail = true
    var isDetachedHead = false
    var isAmend = false
    var largeFiles: [LargeFile] = []
    /// Staged text files whose index version has CRLF (or mixed) endings while `core.autocrlf` is unset.
    var crlfPaths: [String] = []
    var conflictMarkerPaths: [String] = []
    /// Files still in a conflicted state.
    var unresolvedPaths: [String] = []
}

struct IDEGitCommitFinding: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case unresolvedConflicts
        case conflictMarkers
        case authorMissing
        case detachedHead
        case largeFiles
        case lineEndings
    }

    enum Severity: Sendable {
        /// The commit cannot go ahead until it is dealt with.
        case blocking
        /// The user may commit anyway.
        case warning
    }

    let kind: Kind
    let severity: Severity
    let title: String
    let detail: String
    /// The files the finding is about, for Review.
    let paths: [String]

    var id: String { "\(kind)" }
}

/// The pre-commit checks IntelliJ's `GitCheckinHandlerFactory` runs: author configured, detached
/// head, large files, line endings, leftover conflict markers. Pure; gathering the facts is the
/// model's job.
enum IDEGitCommitChecks {
    /// 10 MB, the size above which a file is probably not meant for the repository.
    static let defaultLargeFileLimit = 10 * 1_024 * 1_024

    static func evaluate(_ facts: IDEGitCommitFacts) -> [IDEGitCommitFinding] {
        var findings: [IDEGitCommitFinding] = []
        if !facts.unresolvedPaths.isEmpty {
            findings.append(IDEGitCommitFinding(
                kind: .unresolvedConflicts, severity: .blocking,
                title: "Some files still have conflicts",
                detail: "Resolve them first: \(list(facts.unresolvedPaths)).",
                paths: facts.unresolvedPaths))
        }
        if !facts.hasUserName || !facts.hasUserEmail {
            let missing = [facts.hasUserName ? nil : "user.name", facts.hasUserEmail ? nil : "user.email"].compactMap { $0 }
            findings.append(IDEGitCommitFinding(
                kind: .authorMissing, severity: .blocking,
                title: "Git does not know who you are",
                detail: "\(missing.joined(separator: " and ")) is not set.",
                paths: []))
        }
        if !facts.conflictMarkerPaths.isEmpty {
            findings.append(IDEGitCommitFinding(
                kind: .conflictMarkers, severity: .warning,
                title: "Leftover conflict markers",
                detail: "These staged files still contain <<<<<<< or >>>>>>> lines: \(list(facts.conflictMarkerPaths)).",
                paths: facts.conflictMarkerPaths))
        }
        if facts.isDetachedHead && !facts.isAmend {
            findings.append(IDEGitCommitFinding(
                kind: .detachedHead, severity: .warning,
                title: "HEAD is detached",
                detail: "The commit will not belong to any branch and is easy to lose. Create a branch first to keep it.",
                paths: []))
        }
        if !facts.largeFiles.isEmpty {
            let names = facts.largeFiles.map { "\($0.path) (\(megabytes($0.bytes)))" }
            findings.append(IDEGitCommitFinding(
                kind: .largeFiles, severity: .warning,
                title: "Large files",
                detail: "These files are big for a repository: \(list(names)).",
                paths: facts.largeFiles.map(\.path)))
        }
        if !facts.crlfPaths.isEmpty {
            findings.append(IDEGitCommitFinding(
                kind: .lineEndings, severity: .warning,
                title: "Windows line endings",
                detail: "These files have CRLF line endings in the index: \(list(facts.crlfPaths)).",
                paths: facts.crlfPaths))
        }
        return findings
    }

    static func hasBlocking(_ findings: [IDEGitCommitFinding]) -> Bool {
        findings.contains { $0.severity == .blocking }
    }

    static func megabytes(_ bytes: Int) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    private static func list(_ names: [String], limit: Int = 5) -> String {
        let shown = names.prefix(limit).joined(separator: ", ")
        return names.count > limit ? "\(shown) and \(names.count - limit) more" : shown
    }
}

/// The commit messages of a repository, newest first: what the Recent Messages menu offers.
struct IDEGitRecentMessages {
    static let limit = 20
    private let defaults: UserDefaults
    private let key = "umbra.git.recentMessages"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func messages(for root: String) -> [String] {
        (defaults.dictionary(forKey: key)?[root] as? [String]) ?? []
    }

    func record(_ message: String, for root: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var all = (defaults.dictionary(forKey: key) as? [String: [String]]) ?? [:]
        var list = all[root] ?? []
        list.removeAll { $0 == trimmed }
        list.insert(trimmed, at: 0)
        all[root] = Array(list.prefix(Self.limit))
        defaults.set(all, forKey: key)
    }
}
