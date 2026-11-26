import Foundation

public struct GitRef: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case head
        case localBranch
        case remoteBranch
        case tag
    }

    public let name: String
    public let kind: Kind

    public init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }
}

/// How the current branch stands against its upstream: the commits only here (`outgoing`, what a
/// push sends) and only there (`incoming`, what a pull brings). The lists are capped; `ahead` and
/// `behind` are the true counts.
public struct GitSyncStatus: Sendable, Equatable {
    public let upstream: String
    public let ahead: Int
    public let behind: Int
    public let outgoing: [GitCommit]
    public let incoming: [GitCommit]

    public init(upstream: String, ahead: Int, behind: Int, outgoing: [GitCommit], incoming: [GitCommit]) {
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.outgoing = outgoing
        self.incoming = incoming
    }
}

public struct GitCommit: Sendable, Hashable, Identifiable {
    public let hash: String
    public let parents: [String]
    public let author: String
    public let email: String
    public let date: Date
    public let refs: [GitRef]
    public let subject: String

    public var id: String { hash }
    public var shortHash: String { String(hash.prefix(7)) }
    public var isMerge: Bool { parents.count > 1 }

    public init(hash: String, parents: [String], author: String, email: String, date: Date, refs: [GitRef], subject: String) {
        self.hash = hash
        self.parents = parents
        self.author = author
        self.email = email
        self.date = date
        self.refs = refs
        self.subject = subject
    }
}

public struct GitStatusEntry: Sendable, Hashable, Identifiable {
    public let path: String
    public let originalPath: String?
    public let indexCode: Character
    public let worktreeCode: Character

    public var id: String { path }
    public var isUntracked: Bool { indexCode == "?" && worktreeCode == "?" }
    public var isIgnored: Bool { indexCode == "!" && worktreeCode == "!" }
    public var isConflicted: Bool {
        if isUntracked || isIgnored { return false }
        let pair = "\(indexCode)\(worktreeCode)"
        return pair == "AA" || pair == "DD" || indexCode == "U" || worktreeCode == "U"
    }

    public init(path: String, originalPath: String?, indexCode: Character, worktreeCode: Character) {
        self.path = path
        self.originalPath = originalPath
        self.indexCode = indexCode
        self.worktreeCode = worktreeCode
    }
}

public struct GitChangedFile: Sendable, Hashable, Identifiable {
    public let status: Character
    public let path: String
    public let oldPath: String?

    public var id: String { path }

    public init(status: Character, path: String, oldPath: String?) {
        self.status = status
        self.path = path
        self.oldPath = oldPath
    }
}

/// The commit and path a blamed commit's file had before that commit changed it (porcelain `previous`).
public struct GitBlamePrevious: Sendable, Hashable {
    public let hash: String
    public let path: String

    public init(hash: String, path: String) {
        self.hash = hash
        self.path = path
    }
}

public struct GitBlameLine: Sendable, Hashable {
    public let hash: String
    public let author: String
    public let date: Date
    public let summary: String
    public let isUncommitted: Bool
    public let authorEmail: String
    public let committer: String
    public let committerDate: Date
    /// The 1-based line number in the commit that introduced the line (0 when unknown).
    public let originalLine: Int
    /// The file's path in that commit, which differs from the blamed path after a rename.
    public let originalPath: String
    /// The commit and path before the blamed commit; nil for a root commit or an uncommitted line.
    public let previous: GitBlamePrevious?
    /// True for a line from the oldest commit git was allowed to look at.
    public let isBoundary: Bool

    public var shortHash: String { String(hash.prefix(7)) }

    public init(
        hash: String,
        author: String,
        date: Date,
        summary: String,
        isUncommitted: Bool,
        authorEmail: String = "",
        committer: String = "",
        committerDate: Date? = nil,
        originalLine: Int = 0,
        originalPath: String = "",
        previous: GitBlamePrevious? = nil,
        isBoundary: Bool = false
    ) {
        self.hash = hash
        self.author = author
        self.date = date
        self.summary = summary
        self.isUncommitted = isUncommitted
        self.authorEmail = authorEmail
        self.committer = committer
        self.committerDate = committerDate ?? date
        self.originalLine = originalLine
        self.originalPath = originalPath
        self.previous = previous
        self.isBoundary = isBoundary
    }
}

/// What `git blame` is asked to look through (IntelliJ's Annotate ▸ Options).
public struct GitBlameOptions: Sendable, Hashable {
    /// `-w`: whitespace-only changes do not take a line over.
    public var ignoreWhitespace: Bool
    /// `-M`: lines moved or copied within the file keep their original commit.
    public var detectMovesWithinFile: Bool
    /// `-C`: lines moved or copied from other files changed in the same commit keep their original commit.
    public var detectMovesAcrossFiles: Bool
    /// `--ignore-rev`: commits whose changes blame passes over (formatting, migrations).
    public var ignoredRevisions: [String]

    public static let `default` = GitBlameOptions()

    public init(
        ignoreWhitespace: Bool = false,
        detectMovesWithinFile: Bool = false,
        detectMovesAcrossFiles: Bool = false,
        ignoredRevisions: [String] = []
    ) {
        self.ignoreWhitespace = ignoreWhitespace
        self.detectMovesWithinFile = detectMovesWithinFile
        self.detectMovesAcrossFiles = detectMovesAcrossFiles
        self.ignoredRevisions = ignoredRevisions
    }

    /// The command-line flags, or nil when a revision is not a plain hex object name (it could be
    /// read as an option or a path).
    public func arguments() -> [String]? {
        var args: [String] = []
        if ignoreWhitespace { args.append("-w") }
        if detectMovesWithinFile { args.append("-M") }
        if detectMovesAcrossFiles { args.append("-C") }
        var seen = Set<String>()
        for revision in ignoredRevisions where seen.insert(revision).inserted {
            guard (4...64).contains(revision.count), revision.allSatisfy(\.isHexDigit) else { return nil }
            args.append("--ignore-rev")
            args.append(revision)
        }
        return args
    }
}

/// A version of a file that ``GitRepository/fileContents(at:path:)`` can read.
public enum GitRevision: Sendable, Hashable {
    case head
    /// The staged version.
    case index
    case commit(String)
    /// The commit's first parent; a root commit has none.
    case parent(of: String)
    /// A branch, tag or any other name `git rev-parse` accepts.
    case ref(String)
    /// One side of an unresolved conflict in the index: 1 the common base, 2 "ours" (the commit
    /// being merged into or rebased onto), 3 "theirs" (the commit being merged or replayed).
    case stage(Int)

    /// The `<rev>:<path>` object name git reads the file from.
    func objectName(path: String) -> String {
        switch self {
        case .head: "HEAD:" + path
        case .index: ":" + path
        case .commit(let hash): hash + ":" + path
        case .parent(let hash): hash + "^:" + path
        case .ref(let name): name + ":" + path
        case .stage(let number): ":\(number):" + path
        }
    }
}

/// A staged rename (or copy) to undo with ``GitRepository/discardStagedRenames(_:)``.
public struct GitRenameDiscard: Sendable, Equatable {
    public var newPath: String
    /// The path HEAD has; nil for a copy, whose original was never removed.
    public var oldPath: String?

    public init(newPath: String, oldPath: String?) {
        self.newPath = newPath
        self.oldPath = oldPath
    }
}
