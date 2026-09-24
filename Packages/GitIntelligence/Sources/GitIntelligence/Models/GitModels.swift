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

public struct GitBlameLine: Sendable, Hashable {
    public let hash: String
    public let author: String
    public let date: Date
    public let summary: String
    public let isUncommitted: Bool

    public var shortHash: String { String(hash.prefix(7)) }

    public init(hash: String, author: String, date: Date, summary: String, isUncommitted: Bool) {
        self.hash = hash
        self.author = author
        self.date = date
        self.summary = summary
        self.isUncommitted = isUncommitted
    }
}
