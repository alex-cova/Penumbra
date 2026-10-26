import Foundation
import GitIntelligence
import Observation

/// A sheet the git features show in the window's root view. One is on screen at a time; the rest
/// wait their turn in `IDEGitSheetQueue`.
enum IDEGitSheet: Identifiable {
    case credential(IDEGitCredentialRequest)
    case smartCheckout(IDEGitSmartCheckoutRequest)
    case update(IDEGitUpdateRequest)
    case push(IDEGitPushRequest)
    case textPrompt(IDEGitTextPrompt)
    case confirm(IDEGitConfirmation)
    case deleteMerged(IDEGitDeleteMergedRequest)
    case stash(IDEGitStashRequest)
    case reset(IDEGitResetRequest)
    case rebase(IDEGitRebaseRequest)
    case commitChecks(IDEGitCommitChecksRequest)
    case clone(IDEGitCloneRequest)

    var id: String {
        switch self {
        case .credential(let value): "credential-\(value.id)"
        case .smartCheckout(let value): "smart-\(value.id)"
        case .update(let value): "update-\(value.id)"
        case .push(let value): "push-\(value.id)"
        case .textPrompt(let value): "text-\(value.id)"
        case .confirm(let value): "confirm-\(value.id)"
        case .deleteMerged(let value): "merged-\(value.id)"
        case .stash(let value): "stash-\(value.id)"
        case .reset(let value): "reset-\(value.id)"
        case .rebase(let value): "rebase-\(value.id)"
        case .commitChecks(let value): "checks-\(value.id)"
        case .clone(let value): "clone-\(value.id)"
        }
    }
}

@MainActor
@Observable
final class IDEGitSheetQueue {
    private(set) var current: IDEGitSheet?
    @ObservationIgnored private var pending: [IDEGitSheet] = []

    func present(_ sheet: IDEGitSheet) {
        if current == nil {
            current = sheet
        } else if case .credential = sheet {
            // A git command is blocked on this answer, and it may be the one a sheet underneath
            // started (Clone, Push): it goes first, and the sheet it interrupted comes back after.
            pending.insert(current!, at: 0)
            current = sheet
        } else {
            pending.append(sheet)
        }
    }

    /// The sheet with `id` is done (the user answered it). A stale id is ignored.
    func finish(_ id: String) {
        guard current?.id == id else { return }
        current = pending.isEmpty ? nil : pending.removeFirst()
    }

    /// The system dismissed the current sheet (Esc, a click outside): it counts as Cancel.
    func dismissCurrent() {
        guard let current else { return }
        if case .credential(let request) = current { request.resolve(.cancel) }
        finish(current.id)
    }

    /// The project closed or changed: nothing waiting may keep a git command blocked.
    func cancelAll() {
        let all = ([current] + pending).compactMap { $0 }
        current = nil
        pending = []
        for sheet in all {
            if case .credential(let request) = sheet { request.resolve(.cancel) }
        }
    }
}

// MARK: - Requests

/// A password, passphrase or confirmation git (or ssh) is waiting for. It is answered once.
@MainActor
final class IDEGitCredentialRequest: Identifiable {
    let id = UUID()
    let prompt: String
    let kind: IDEGitCredentialPromptKind
    private var continuation: CheckedContinuation<IDEGitAskPassReply, Never>?

    init(prompt: String, continuation: CheckedContinuation<IDEGitAskPassReply, Never>) {
        self.prompt = prompt
        self.kind = IDEGitCredentialPromptKind.classify(prompt)
        self.continuation = continuation
    }

    func resolve(_ reply: IDEGitAskPassReply) {
        continuation?.resume(returning: reply)
        continuation = nil
    }

    func answer(_ text: String) { resolve(IDEGitAskPassReply(answer: text, cancelled: false)) }
}

/// A checkout git refused because local changes are in the way.
struct IDEGitSmartCheckoutRequest: Identifiable {
    let id = UUID()
    /// The local branch, or the remote-tracking branch (`origin/feature`) when `isRemote`.
    let branch: String
    let isRemote: Bool
    let files: [String]
}

struct IDEGitUpdateRequest: Identifiable {
    let id = UUID()
    let branch: String?
    let upstream: String?
    let strategy: GitPullStrategy
}

struct IDEGitPushRequest: Identifiable {
    let id = UUID()
    let branch: String
    let remotes: [String]
    let remote: String
    let targetBranch: String
    /// The branch has no upstream yet, so the push sets one.
    let setsUpstream: Bool
}

struct IDEGitTextPrompt: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let placeholder: String
    var initial: String = ""
    let confirmTitle: String
    /// A reason the text cannot be used, or nil when it can.
    var validate: (String) -> String? = { $0.trimmingCharacters(in: .whitespaces).isEmpty ? "Enter a name." : nil }
    let action: @MainActor (String) -> Void
}

struct IDEGitConfirmation: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirmTitle: String
    var isDestructive = false
    let action: @MainActor () -> Void
}

struct IDEGitCloneRequest: Identifiable {
    let id = UUID()
    let model: IDEGitCloneModel
}

struct IDEGitCommitChecksRequest: Identifiable {
    let id = UUID()
    let findings: [IDEGitCommitFinding]
    let options: IDEGitCommitOptions
    let message: String
}

struct IDEGitResetRequest: Identifiable {
    let id = UUID()
    let hash: String
    let shortHash: String
    let subject: String
    let branch: String?
    /// Remote branches that already hold the commits the reset would drop.
    let publishedOn: [String]
}

struct IDEGitRebaseRequest: Identifiable {
    let id = UUID()
    let base: String
    /// The commits oldest first, as git replays them.
    let steps: [GitRebaseStep]
    /// Remote branches that already hold some of these commits: rewriting them needs a force push.
    let publishedOn: [String]
}

/// The history of a line range, listed in place of the log.
struct IDEGitLineHistory: Equatable {
    let path: String
    let startLine: Int
    let endLine: Int
    var entries: [GitLineHistoryEntry]
    var selectedHash: String?
}

struct IDEGitStashRequest: Identifiable {
    let id = UUID()
    let branch: String?
    /// Untracked files exist, so "Include untracked files" matters.
    let hasUntracked: Bool
}

struct IDEGitDeleteMergedRequest: Identifiable {
    let id = UUID()
    let base: String
    let candidates: [String]
}
