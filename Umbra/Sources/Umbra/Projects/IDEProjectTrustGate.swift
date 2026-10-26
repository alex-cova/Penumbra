import Foundation
import JavaIntelligence

/// The trust question every project system asks before it runs a project's own scripts: build
/// scripts, run phases and install hooks all execute arbitrary code, so an untrusted project is
/// asked first and a "yes" is remembered in the shared ``ProjectTrustStore``.
///
/// The five systems differed only in three details, which are parameters here:
/// - whether a "no" is remembered (`recordDeclined`: npm's reload remembers it so it stops
///   asking; the runners don't, so a "no" asks again next time),
/// - what revalidates the answer after an asynchronous prompt (`isCurrent`: the generation
///   counters that prove the project didn't change while the prompt was open),
/// - what happens after a "yes" (each caller flips its own `syncState` and refines its model).
/// Gradle's sync keeps its own flow — a previously declined root is not re-asked and a missing
/// prompt lands in `.awaitingTrust` — and only shares the store.
@MainActor
struct IDEProjectTrustGate {
    let store: ProjectTrustStore
    let prompt: (@MainActor (URL) async -> Bool)?

    /// True when `root` may run: already trusted, or the user says yes when asked. A "yes" is
    /// always remembered; a "no" is remembered only when `recordDeclined` is set. When
    /// `isCurrent` is provided and reports false after the prompt returns, nothing is recorded
    /// and the answer is false, exactly as if the user had said no.
    func confirmTrust(
        for root: URL,
        recordDeclined: Bool = false,
        isCurrent: (@MainActor () -> Bool)? = nil
    ) async -> Bool {
        if store.isTrusted(root) { return true }
        guard let prompt else {
            // No suspension happened, so the caller's generation is still current: record exactly
            // as the inline reload flows did when no prompt was wired.
            if recordDeclined { store.setTrusted(false, for: root) }
            return false
        }
        let trusted = await prompt(root)
        if let isCurrent, isCurrent() == false { return false }
        if trusted || recordDeclined { store.setTrusted(trusted, for: root) }
        return trusted
    }
}
