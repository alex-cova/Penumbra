import Foundation
import Penumbra

/// The window's large-file session state (F11, F25): which paths were sniffed as binary, which
/// the user lifted to full service, the size tiers files open under, and which oversized notices
/// already posted. The banner, the loader and the hex opener read this; none of it is observed
/// by views, so it is a plain owner, not an observable store.
@MainActor
final class IDELargeFileState {
    /// The size tiers files open under. Tests lower them; the app always uses the standard ones.
    var basePolicy: LargeFilePolicy = .standard
    /// Files the user chose to open with full service although they are over the large-file size
    /// (Enable Anyway). For this window's session only.
    private var liftedPaths: Set<String> = []
    /// Paths opened as hex because the first 8 KB did not look like text. Consumed when the
    /// session starts.
    private var sniffedPaths: Set<String> = []
    /// Oversized-source-file notices already posted, so a re-walk does not repeat one.
    private var postedNoticeKeys: Set<String> = []

    func policy(for url: URL) -> LargeFilePolicy {
        liftedPaths.contains(url.standardizedFileURL.path) ? .disabled : basePolicy
    }

    func lift(_ path: String) {
        liftedPaths.insert(path)
    }

    func isLifted(_ path: String) -> Bool {
        liftedPaths.contains(path)
    }

    func unlift(_ path: String) {
        liftedPaths.remove(path)
    }

    func markSniffed(_ path: String) {
        sniffedPaths.insert(path)
    }

    /// Takes a pending sniff mark, once: a second open of the same path is not "sniffed" again.
    func consumeSniffed(_ path: String) -> Bool {
        sniffedPaths.remove(path) != nil
    }

    /// True the first time `key` is seen: each notice posts once per window.
    func noticeOnce(key: String) -> Bool {
        postedNoticeKeys.insert(key).inserted
    }
}
