import Observation
import SwiftUI

/// Connects the SwiftUI toolbar to its viewer, which owns the text views the actions move.
@MainActor
@Observable
final class IDEDiffToolbarModel {
    @ObservationIgnored weak var viewer: IDEDiffViewerView?
    var session: IDEDiffSession?
    /// Bumped when the viewer changed something the session does not publish.
    private(set) var revision = 0

    func refresh() {
        revision &+= 1
    }
}
