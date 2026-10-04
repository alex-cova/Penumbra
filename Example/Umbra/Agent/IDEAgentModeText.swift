import AgentKit

extension PermissionMode {
    var title: String {
        switch self {
        case .manual: "Manual"
        case .acceptEdits: "Accept Edits"
        case .auto: "Auto"
        case .plan: "Plan"
        }
    }

    var detail: String {
        switch self {
        case .manual: "Every edit shows its diff and waits for Apply or Reject, and every command asks."
        case .acceptEdits: "Edits apply at once and Revert Run undoes a whole run. Commands ask."
        case .auto: "Edits apply at once. Commands that only read (ls, grep, git status…) or that your rules allow run without asking; any other command asks."
        case .plan: "The agent can read and search but not change files or run commands; it proposes a plan for you to approve."
        }
    }

    var symbol: String {
        switch self {
        case .manual: "hand.raised"
        case .acceptEdits: "pencil.line"
        case .auto: "bolt"
        case .plan: "list.bullet.clipboard"
        }
    }
}
