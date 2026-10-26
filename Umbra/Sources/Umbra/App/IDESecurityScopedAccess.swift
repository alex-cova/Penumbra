import Foundation

/// Holds one security-scoped access to a folder for as long as a window needs it, and gives it back
/// exactly once. Every `startAccessingSecurityScopedResource()` has to be balanced by a stop, or the
/// sandbox extension stays in use for the life of the process. That did not matter while the app had
/// one project; with several windows opening and closing projects it would pile up.
///
/// `begin` replaces any previous folder (releasing it first), so a window that switches projects
/// never holds two.
final class IDESecurityScopedAccess {
    private var url: URL?
    private var isActive = false

    /// The folder currently held, if any.
    var heldURL: URL? { isActive ? url : nil }

    /// Starts access to `url` and releases the previously held folder. Nil just releases.
    func begin(_ url: URL?) {
        end()
        guard let url else { return }
        self.url = url
        isActive = url.startAccessingSecurityScopedResource()
    }

    /// Releases the held folder. Safe to call again.
    func end() {
        if isActive {
            url?.stopAccessingSecurityScopedResource()
        }
        isActive = false
        url = nil
    }

    deinit {
        end()
    }
}
