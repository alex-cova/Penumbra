import Foundation

/// Debounces and offloads ``FindSearchEngine`` scans driven by a ``FindSession``, so query typing
/// and document edits don't block the main thread.
///
/// Staleness is guarded two ways: the debounce/search `Task`s are cancelled outright when a newer
/// request comes in, and the in-flight result is additionally checked against `isCurrent()` and
/// the session's `SearchSnapshot` before being applied — so a slow search for a query the user has
/// since changed (or a document the user has since navigated away from) never clobbers a newer
/// result.
///
/// Long scans also stream incomplete ``FindSearchOutcome`` snapshots via `onProgress` so the find
/// panel can fill in as matches arrive rather than keeping stale counts until the scan finishes.
@MainActor
public final class FindSearchScheduler {
    /// 200ms — matches the debounce interval most find-bar implementations settle on.
    public static let debounceNanoseconds: UInt64 = 200_000_000

    private var debounceTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var searchGeneration: UInt64 = 0

    public init() {}

    public func cancel() {
        debounceTask?.cancel()
        searchTask?.cancel()
        searchGeneration &+= 1
    }

    /// Schedules a search for `session`'s current query/options against `text`.
    public func scheduleRefresh(
        session: FindSession,
        text: String,
        anchorLocation: Int,
        immediate: Bool = false,
        isCurrent: @escaping @MainActor () -> Bool = { true },
        apply: @escaping @MainActor () -> Void
    ) {
        scheduleRefresh(
            session: session,
            source: StringFindTextSource(text),
            anchorLocation: anchorLocation,
            immediate: immediate,
            isCurrent: isCurrent,
            apply: apply
        )
    }

    /// Schedules a search for `session`'s current query/options against `source`.
    ///
    /// The detached scan captures `source` (a snapshot or string wrapper), not a newly
    /// bridged `String`.
    /// - Parameters:
    ///   - immediate: Skips the debounce delay — use for e.g. showing the find bar with an
    ///     already-known query, where waiting would read as unresponsive.
    ///   - isCurrent: Checked before applying a result, in case the caller's context (active
    ///     document, visible panel, etc.) changed while the search was in flight. Defaults to
    ///     always current.
    ///   - apply: Called on the main actor after `session.applySearchOutcome(_:)` has already run.
    public func scheduleRefresh(
        session: FindSession,
        source: any FindTextSource,
        anchorLocation: Int,
        immediate: Bool = false,
        isCurrent: @escaping @MainActor () -> Bool = { true },
        apply: @escaping @MainActor () -> Void
    ) {
        debounceTask?.cancel()
        if immediate {
            runSearch(session: session, source: source, anchorLocation: anchorLocation, isCurrent: isCurrent, apply: apply)
            return
        }
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            guard !Task.isCancelled else { return }
            runSearch(session: session, source: source, anchorLocation: anchorLocation, isCurrent: isCurrent, apply: apply)
        }
    }

    private func runSearch(
        session: FindSession,
        source: any FindTextSource,
        anchorLocation: Int,
        isCurrent: @escaping @MainActor () -> Bool,
        apply: @escaping @MainActor () -> Void
    ) {
        searchTask?.cancel()
        searchGeneration &+= 1
        let generation = searchGeneration
        let snapshot = FindSession.SearchSnapshot(
            query: session.query,
            matchCase: session.matchCase,
            wholeWord: session.wholeWord,
            useRegex: session.useRegex
        )
        let searchSource = source
        let anchor = anchorLocation
        let gate = SearchApplyGate()

        if snapshot.query.isEmpty {
            guard isCurrent() else { return }
            session.applySearchOutcome(.empty)
            apply()
            return
        }

        searchTask = Task { @MainActor [weak self] in
            let options = FindSearchOptions(
                query: snapshot.query,
                matchCase: snapshot.matchCase,
                wholeWord: snapshot.wholeWord,
                useRegex: snapshot.useRegex
            )
            let applyPartial: @Sendable (FindSearchOutcome) -> Void = { [weak self] partial in
                Task { @MainActor in
                    guard let self, generation == self.searchGeneration, gate.shouldApply else { return }
                    guard isCurrent(), session.matchesSnapshot(snapshot) else { return }
                    session.applySearchOutcome(partial)
                    apply()
                }
            }
            let outcome = await Task.detached(priority: .userInitiated) {
                FindSearchEngine.search(
                    options: options,
                    in: searchSource,
                    anchorLocation: anchor,
                    onProgress: applyPartial
                )
            }.value

            gate.finish()
            guard let self, generation == self.searchGeneration else { return }
            guard !Task.isCancelled else { return }
            guard isCurrent(), session.matchesSnapshot(snapshot) else { return }

            session.applySearchOutcome(outcome)
            apply()
        }
    }
}

/// Serializes incomplete progress updates against the final outcome so a late `Task { @MainActor }`
/// progress hop cannot clobber the completed snapshot.
private final class SearchApplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    var shouldApply: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !finished
    }

    func finish() {
        lock.lock()
        finished = true
        lock.unlock()
    }
}
