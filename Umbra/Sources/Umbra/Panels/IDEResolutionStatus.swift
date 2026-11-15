import Foundation
import JavaIntelligence

/// Whether the Problems panel can call a file's missing-class checks done. Pure: built from the
/// inspection service's `JavaResolutionReadiness` and what the window is still indexing.
///
/// - `complete`: the checks ran against an authoritative index; "No problems" means no problems.
/// - `pending`: they did not run yet because indexing that will finish is still going. Shown as a
///   quiet note, never a spinner, and it ends by itself when the index is published.
/// - `unavailable`: they cannot run because nothing more will arrive (no JDK, a project that was
///   not synced, a jar that failed to index). Shown with what is missing and one action.
enum IDEResolutionStatus: Equatable, Sendable {
    case complete
    case pending(String)
    case unavailable(String, action: Action?)

    enum Action: Equatable, Sendable {
        case syncProject
        case chooseJDK
    }

    /// What is still running in the window.
    struct Activity: Equatable, Sendable {
        var isIndexingJDK = false
        var isIndexingSources = false
        var isIndexingDependencies = false
        var isSyncing = false
        /// A Gradle or Maven project whose model is not there and no sync is running.
        var awaitsProjectModel = false

        var isBusy: Bool { isIndexingJDK || isIndexingSources || isIndexingDependencies || isSyncing }
    }

    /// `readiness` is the file's last result (`nil`: authoritative). `rootName` turns a shard path
    /// into a jar or folder name a person recognises.
    static func make(
        readiness: JavaResolutionReadiness?, activity: Activity, rootName: (String) -> String?
    ) -> IDEResolutionStatus {
        guard let readiness else { return .complete }
        if readiness.platformMissing {
            if activity.isIndexingJDK { return .pending("Missing-class checks start when the JDK is indexed.") }
            return .unavailable("No JDK is indexed, so missing classes are not reported.", action: .chooseJDK)
        }
        if readiness.classpathIncomplete {
            if activity.awaitsProjectModel && !activity.isSyncing {
                return .unavailable("The project has not been synced, so its dependencies are unknown and missing classes are not reported.", action: .syncProject)
            }
            return .pending("Missing-class checks start when the project is indexed.")
        }
        if !readiness.missingShards.isEmpty {
            if activity.isIndexingDependencies || activity.isIndexingSources || activity.isSyncing {
                return .pending("Missing-class checks start when the dependencies are indexed.")
            }
            let names = readiness.missingShards.compactMap(rootName).sorted()
            let what = names.isEmpty ? "A classpath entry" : names.prefix(2).joined(separator: ", ") + (names.count > 2 ? " and \(names.count - 2) more" : "")
            return .unavailable("\(what) could not be indexed, so missing classes are not reported for this module.", action: .syncProject)
        }
        return .pending("Missing-class checks start when indexing finishes.")
    }

    /// One line for the whole panel: anything unavailable wins over pending, pending over complete.
    static func summary(_ statuses: some Sequence<IDEResolutionStatus>) -> IDEResolutionStatus {
        var pending: IDEResolutionStatus?
        for status in statuses {
            switch status {
            case .unavailable: return status
            case .pending: pending = pending ?? status
            case .complete: continue
            }
        }
        return pending ?? .complete
    }

    var message: String? {
        switch self {
        case .complete: nil
        case .pending(let text): text
        case .unavailable(let text, _): text
        }
    }
}
