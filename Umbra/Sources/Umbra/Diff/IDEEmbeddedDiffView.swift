import AppKit
import SwiftUI

/// The diff viewer inside a panel instead of an editor tab. History and the Changes preview each
/// keep one viewer and one session for the life of the view; picking another file swaps the
/// session's request (`IDEDiffSession.show(request:siblings:)`) rather than rebuilding it.
///
/// History stores its options under `IDEDiffSettings.embeddedPrefix` and starts unified. The
/// Changes preview uses `changesPrefix` and starts side-by-side. A layout pick in one stays there.
struct IDEEmbeddedDiffView: NSViewRepresentable {
    var workspace: IDEWorkspace
    var request: IDEDiffRequest
    var siblings: [IDEDiffRequest]
    var settingsPrefix: String = IDEDiffSettings.embeddedPrefix
    var defaultLayout: IDEDiffLayout = .unified
    /// The epoch of the status snapshot now showing. A newer epoch reloads this session when its
    /// file is in `reloadPaths`. The tab store does not own this session, so the view reloads itself.
    var reloadEpoch: UInt64 = 0
    var reloadPaths: Set<String> = []
    /// Repository-relative path of the file on screen. Untracked requests have no revision side,
    /// so this is the change's path rather than `IDEDiffRequest.repositoryRelativePath`.
    var reloadRelativePath: String? = nil
    /// The viewer moved to another file itself (Previous/Next File, F7 past the last change).
    var onRequestChanged: (IDEDiffRequest) -> Void

    func makeNSView(context: Context) -> IDEDiffViewerView {
        let viewer = IDEDiffViewerView()
        context.coordinator.viewer = viewer
        context.coordinator.update(self)
        return viewer
    }

    func updateNSView(_ viewer: IDEDiffViewerView, context: Context) {
        IDEBodyDiagnostics.note("IDEEmbeddedDiffView")
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
        /// The status epoch already applied to `session`. A repeated SwiftUI update does not reload.
        private var appliedReloadEpoch: UInt64 = 0

        func update(_ view: IDEEmbeddedDiffView) {
            onRequestChanged = view.onRequestChanged
            if let session {
                let idChanged = session.request.id != view.request.id
                if idChanged || session.siblings != view.siblings {
                    isApplying = true
                    session.show(request: view.request, siblings: view.siblings)
                    isApplying = false
                }
                consumeReload(view, session: session, alreadyLoaded: idChanged)
                return
            }
            guard let viewer else { return }
            appliedReloadEpoch = view.reloadEpoch
            let session = view.workspace.makeEmbeddedDiffSession(
                view.request,
                siblings: view.siblings,
                settingsPrefix: view.settingsPrefix,
                defaultLayout: view.defaultLayout
            )
            session.onRequestChanged = { [weak self, weak session] in
                guard let self, !self.isApplying, let session else { return }
                self.onRequestChanged?(session.request)
            }
            self.session = session
            weak let workspace = view.workspace
            viewer.onJumpToSource = { path, line in workspace?.openDiffSource(path: path, line: line) }
            viewer.show(session, preferences: view.workspace.preferences)
        }

        /// A newer status snapshot reloads this file. `show` already loaded a request whose id changed.
        /// A dirty right side is left alone, the same rule as `IDEDiffSessionStore.reload`.
        private func consumeReload(_ view: IDEEmbeddedDiffView, session: IDEDiffSession, alreadyLoaded: Bool) {
            guard view.reloadEpoch != appliedReloadEpoch else { return }
            appliedReloadEpoch = view.reloadEpoch
            guard !alreadyLoaded else { return }
            guard IDEEmbeddedDiffReload.shouldReload(
                relativePath: view.reloadRelativePath,
                paths: view.reloadPaths,
                isRightDirty: session.isRightDirty
            ) else { return }
            session.reload()
        }

        func teardown() {
            guard let session else { return }
            viewer?.detach(session)
            session.cancel()
            self.session = nil
        }
    }
}

/// Whether an embedded diff should reload after a status snapshot. The tab store applies the same
/// rule to its own sessions; this one is for the sidebar, which the store does not hold.
enum IDEEmbeddedDiffReload {
    static func shouldReload(relativePath: String?, paths: Set<String>, isRightDirty: Bool) -> Bool {
        guard !isRightDirty, let relativePath, paths.contains(relativePath) else { return false }
        return true
    }
}
