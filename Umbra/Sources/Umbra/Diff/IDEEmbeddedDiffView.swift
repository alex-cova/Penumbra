import AppKit
import SwiftUI

/// The diff viewer inside a panel instead of an editor tab: the History pane shows the file picked
/// under a commit with it. One viewer and one session live as long as the view; picking another file
/// swaps the session's request (`IDEDiffSession.show(request:siblings:)`) rather than rebuilding.
///
/// The session is read-only in practice (commit sides are revisions) and keeps its own options
/// (`IDEDiffSettings.embeddedPrefix`), unified until the user picks another layout.
struct IDEEmbeddedDiffView: NSViewRepresentable {
    let workspace: IDEWorkspace
    let request: IDEDiffRequest
    let siblings: [IDEDiffRequest]
    /// The viewer moved to another file itself (Previous/Next File, F7 past the last change).
    let onRequestChanged: (IDEDiffRequest) -> Void

    func makeNSView(context: Context) -> IDEDiffViewerView {
        let viewer = IDEDiffViewerView()
        context.coordinator.viewer = viewer
        context.coordinator.update(self)
        return viewer
    }

    func updateNSView(_ viewer: IDEDiffViewerView, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleNSView(_ viewer: IDEDiffViewerView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        weak var viewer: IDEDiffViewerView?
        private(set) var session: IDEDiffSession?
        private var onRequestChanged: ((IDEDiffRequest) -> Void)?
        /// True while SwiftUI is applying a request, so the echo is not reported back as a user move.
        private var isApplying = false

        func update(_ view: IDEEmbeddedDiffView) {
            onRequestChanged = view.onRequestChanged
            if let session {
                isApplying = true
                session.show(request: view.request, siblings: view.siblings)
                isApplying = false
                return
            }
            guard let viewer else { return }
            let session = view.workspace.makeEmbeddedDiffSession(view.request, siblings: view.siblings)
            session.onRequestChanged = { [weak self, weak session] in
                guard let self, !self.isApplying, let session else { return }
                self.onRequestChanged?(session.request)
            }
            self.session = session
            weak let workspace = view.workspace
            viewer.onJumpToSource = { path, line in workspace?.openDiffSource(path: path, line: line) }
            viewer.show(session, preferences: view.workspace.preferences)
        }

        func teardown() {
            guard let session else { return }
            viewer?.detach(session)
            session.cancel()
            self.session = nil
        }
    }
}
