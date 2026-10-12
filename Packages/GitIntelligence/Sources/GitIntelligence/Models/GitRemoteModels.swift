import Foundation

public struct GitRemote: Sendable, Hashable, Identifiable {
    public let name: String
    public let fetchURL: String
    public let pushURL: String

    public var id: String { name }

    public init(name: String, fetchURL: String, pushURL: String) {
        self.name = name
        self.fetchURL = fetchURL
        self.pushURL = pushURL
    }
}

/// A local or remote-tracking branch with what the branch list needs: where it points, what it
/// tracks, and how far it is from that, all from one `for-each-ref`.
public struct GitBranch: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case local
        case remote
    }

    /// `main` for a local branch, `origin/main` for a remote one.
    public let name: String
    public let kind: Kind
    public let hash: String
    public let isCurrent: Bool
    /// The tracked branch (`origin/main`), when a local branch has one.
    public let upstream: String?
    public let ahead: Int
    public let behind: Int
    /// The upstream was deleted on the remote.
    public let upstreamIsGone: Bool
    public let lastCommitDate: Date

    public var id: String { (kind == .local ? "heads/" : "remotes/") + name }

    /// `origin` for `origin/main`, nil for a local branch.
    public var remoteName: String? {
        guard kind == .remote, let slash = name.firstIndex(of: "/") else { return nil }
        return String(name[..<slash])
    }

    /// `main` for `origin/main`, the name itself for a local branch.
    public var shortName: String {
        guard kind == .remote, let slash = name.firstIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }

    public init(
        name: String, kind: Kind, hash: String, isCurrent: Bool, upstream: String? = nil,
        ahead: Int = 0, behind: Int = 0, upstreamIsGone: Bool = false, lastCommitDate: Date = Date(timeIntervalSince1970: 0)
    ) {
        self.name = name
        self.kind = kind
        self.hash = hash
        self.isCurrent = isCurrent
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.upstreamIsGone = upstreamIsGone
        self.lastCommitDate = lastCommitDate
    }
}

public struct GitTag: Sendable, Hashable, Identifiable {
    public let name: String
    /// The commit the tag points at (an annotated tag is peeled).
    public let commit: String
    public let isAnnotated: Bool
    public let subject: String
    public let date: Date

    public var id: String { name }

    public init(name: String, commit: String, isAnnotated: Bool, subject: String, date: Date) {
        self.name = name
        self.commit = commit
        self.isAnnotated = isAnnotated
        self.subject = subject
        self.date = date
    }
}

public enum GitPullStrategy: Sendable, Hashable {
    /// Fails when the branches diverged; changes nothing then.
    case fastForwardOnly
    case merge
    case rebase
}

public struct GitPushOptions: Sendable, Equatable {
    public enum Tags: Sendable, Equatable {
        case none
        /// Annotated tags that point into the pushed commits (`--follow-tags`).
        case following
        /// Every tag (`--tags`).
        case all
    }

    /// The remote to push to; nil uses the branch's configured remote.
    public var remote: String?
    /// A branch, `HEAD` or a commit id.
    public var source: String
    /// The branch name on the remote; nil pushes `source` under its own name (or the configured
    /// upstream when `remote` is also nil).
    public var targetBranch: String?
    public var setUpstream: Bool
    /// `--force-with-lease`: refuses when the remote branch moved since the last fetch.
    public var forceWithLease: Bool
    public var tags: Tags

    public init(
        remote: String? = nil, source: String = "HEAD", targetBranch: String? = nil,
        setUpstream: Bool = false, forceWithLease: Bool = false, tags: Tags = .none
    ) {
        self.remote = remote
        self.source = source
        self.targetBranch = targetBranch
        self.setUpstream = setUpstream
        self.forceWithLease = forceWithLease
        self.tags = tags
    }
}

/// Two revisions side by side: what each has that the other lacks, and the files that differ
/// between their tips.
public struct GitComparison: Sendable, Equatable {
    public let left: String
    public let right: String
    public let onlyInLeft: [GitCommit]
    public let onlyInRight: [GitCommit]
    public let files: [GitChangedFile]

    public init(left: String, right: String, onlyInLeft: [GitCommit], onlyInRight: [GitCommit], files: [GitChangedFile]) {
        self.left = left
        self.right = right
        self.onlyInLeft = onlyInLeft
        self.onlyInRight = onlyInRight
        self.files = files
    }
}

/// What a smart operation (checkout, update) did with the user's local changes.
public enum GitPreserveOutcome: Sendable, Equatable {
    /// Nothing needed saving, or the changes were put back cleanly.
    case completed
    /// The changes were put back and some files now have conflicts. Git kept the stash.
    case restoredWithConflicts
    /// The operation worked but the changes could not be applied; they are still in the stash.
    case keptInStash
}

/// The files git names when it refuses to switch because local changes would be overwritten.
public enum GitSwitchConflictParser {
    /// nil when `stderr` is some other failure.
    public static func parse(_ stderr: String) -> [String]? {
        let lines = stderr.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: {
            $0.contains("would be overwritten by checkout") || $0.contains("would be overwritten by merge")
                || $0.contains("would be overwritten by switch")
        }) else { return nil }
        var files: [String] = []
        for line in lines[(start + 1)...] {
            guard line.hasPrefix("\t") || line.hasPrefix("    ") else { break }
            let name = line.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { files.append(name) }
        }
        return files
    }
}
