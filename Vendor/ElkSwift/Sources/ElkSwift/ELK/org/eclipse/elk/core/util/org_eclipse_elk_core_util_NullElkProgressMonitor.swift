import Foundation

/**
 * An implementation of `IElkProgressMonitor` which does not do anything. The primary purpose of this monitor is
 * for it to be used with unit tests. The only method which returns something sensible is `subTask(_:)`, which
 * simply returns the instance it was called on (since the progress monitor doesn't do anything anyway, we don't bother
 * creating a new instance).
 */
package class NullElkProgressMonitor: IElkProgressMonitor {

    package static let UNKNOWN_WORK: Float = -1

    package var taskName: String { return "" }
    package var subMonitors: [IElkProgressMonitor] { return [] }
    package var parentMonitor: (any IElkProgressMonitor)? { return nil }
    package var logs: [String] { return [] }
    package var loggedGraphs: [LoggedGraph] { return [] }
    package var debugFolder: URL? { return nil }
    package var executionTime: Double { return 0 }

    package init() {}

    package func isCanceled() -> Bool {
        return false
    }

    @discardableResult
    package func begin(_ name: String, _ totalWork: Float) -> Bool {
        return true
    }

    package func worked(_ work: Float) {
    }

    package func done() {
    }

    package func isRunning() -> Bool {
        return false
    }

    package func subTask(_ work: Float) -> (any IElkProgressMonitor)? {
        return self
    }

    package func isLoggingEnabled() -> Bool {
        return false
    }

    package func isLogPersistenceEnabled() -> Bool {
        return false
    }

    package func log(_ object: Any) {
    }

    package func logGraph(_ graph: ElkNode, _ tag: String) {
    }

    package func logGraph(_ graph: Any, _ tag: String, _ graphType: LoggedGraph.GraphType = .elk) {
    }

    package func isExecutionTimeMeasured() -> Bool {
        return false
    }
}
