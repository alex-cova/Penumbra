import Foundation

/// Painted order of the branch popup: repository actions (while search is empty), then local
/// branches, remotes, tags.
enum IDEGitBranchPopupKeyboard {
    enum Action: String, CaseIterable {
        case update
        case fetch
        case push
        case newBranch
        case checkoutRevision
        case deleteMerged

        var id: String { "action:\(rawValue)" }

        var title: String {
            switch self {
            case .update: "Update Project…"
            case .fetch: "Fetch"
            case .push: "Push…"
            case .newBranch: "New Branch…"
            case .checkoutRevision: "Checkout Tag or Revision…"
            case .deleteMerged: "Delete Merged Branches…"
            }
        }

        var systemImage: String {
            switch self {
            case .update: "arrow.down.circle"
            case .fetch: "arrow.triangle.2.circlepath"
            case .push: "arrow.up.circle"
            case .newBranch: "plus"
            case .checkoutRevision: "tag"
            case .deleteMerged: "trash"
            }
        }

        init?(id: String) {
            guard id.hasPrefix("action:") else { return nil }
            self.init(rawValue: String(id.dropFirst("action:".count)))
        }
    }

    static func tagID(_ name: String) -> String { "tag/\(name)" }

    static func order(
        showingActions: Bool,
        localIDs: [String],
        remoteIDs: [String],
        tagNames: [String]
    ) -> [String] {
        var ids: [String] = []
        if showingActions { ids.append(contentsOf: Action.allCases.map(\.id)) }
        ids.append(contentsOf: localIDs)
        ids.append(contentsOf: remoteIDs)
        ids.append(contentsOf: tagNames.map(tagID))
        return ids
    }
}
