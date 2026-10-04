import AgentKit

extension AutonomyMode {
    var title: String {
        switch self {
        case .autoApplyEdits: "Apply edits automatically"
        case .approveEachEdit: "Approve each edit"
        case .planOnly: "Plan only"
        }
    }

    var detail: String {
        switch self {
        case .autoApplyEdits: "Edits apply at once and Revert Run undoes a whole run. Commands always ask."
        case .approveEachEdit: "Every edit shows its diff and waits for Apply or Reject. Commands always ask."
        case .planOnly: "The agent can read and search but not change files or run commands; it proposes a plan instead."
        }
    }
}
