import SwiftUI

/// Copies the Problems list as shown; an Inspect Code run has its own results view,
/// so it is not exported here.
struct IDEProblemsCopyButton: View {
    @Environment(IDEWorkspace.self) private var workspace
    @State private var didCopy = false

    var body: some View {
        let visible = workspace.visibleProblems()
        let canCopy = workspace.inspectionRuns.selectedRun == nil && !(visible.files.isEmpty && visible.messages.isEmpty)
        return IDEIconButton(
            systemImage: didCopy ? "checkmark" : "doc.on.doc",
            help: "Copy Problems as Markdown",
            isDisabled: !canCopy,
            action: copy
        )
    }

    private func copy() {
        workspace.copyProblemsAsMarkdown()
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            didCopy = false
        }
    }
}
