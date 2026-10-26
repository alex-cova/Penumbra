import Foundation
import GitIntelligence

/// How the banner, the toolbar badge and the merge tab name an operation in progress. Pure, so it
/// is tested without a window.
struct IDEGitOperationPresentation: Equatable {
    var title: String
    /// "2 of 5" for a rebase that says how far it is.
    var progress: String?
    /// Short name for the toolbar badge.
    var badge: String
    var leftTitle: String
    var rightTitle: String
    var canSkip: Bool

    init(operation: GitOperationState, currentBranch: String?) {
        let head = currentBranch ?? "HEAD"
        func short(_ hash: String?) -> String { hash.map { String($0.prefix(7)) } ?? "commit" }
        switch operation.kind {
        case .merge:
            let incoming = Self.mergedBranch(from: operation.message) ?? short(operation.heads.first)
            title = "Merging \(incoming) into \(head)"
            badge = "Merging"
            leftTitle = "Yours (\(head))"
            rightTitle = "Theirs (\(incoming))"
            canSkip = false
        case .rebase:
            let branch = operation.branch ?? head
            title = "Rebasing \(branch) onto \(short(operation.onto))"
            badge = "Rebasing"
            leftTitle = "Upstream (\(short(operation.onto)))"
            rightTitle = "Your commit (\(branch))"
            canSkip = true
        case .cherryPick:
            title = "Cherry-picking \(short(operation.heads.first))"
            badge = "Cherry-picking"
            leftTitle = "Current (\(head))"
            rightTitle = "Incoming (\(short(operation.heads.first)))"
            canSkip = true
        case .revert:
            title = "Reverting \(short(operation.heads.first))"
            badge = "Reverting"
            leftTitle = "Current (\(head))"
            rightTitle = "Reverted state (\(short(operation.heads.first)))"
            canSkip = true
        case .applyMailbox:
            title = "Applying patches"
            badge = "Applying"
            leftTitle = "Current (\(head))"
            rightTitle = "Patch"
            canSkip = true
        case .bisect:
            title = "Bisecting"
            badge = "Bisecting"
            leftTitle = "Current"
            rightTitle = "Other"
            canSkip = false
        }
        if let step = operation.step, let total = operation.total, total > 0 {
            progress = "\(step) of \(total)"
        } else {
            progress = nil
        }
    }

    /// `feature` out of `Merge branch 'feature' into main` or `Merge remote-tracking branch 'origin/x'`.
    static func mergedBranch(from message: String?) -> String? {
        guard let message, let open = message.firstIndex(of: "'") else { return nil }
        let rest = message[message.index(after: open)...]
        guard let close = rest.firstIndex(of: "'") else { return nil }
        let name = String(rest[..<close])
        return name.isEmpty ? nil : name
    }
}
