import Foundation

/// The terminal views SwiftUI created for this window's tabs, weakly. A running shell keeps its
/// view alive, so closing the window has to end the shell itself rather than wait for SwiftUI to
/// dismantle the view. Views are never observed through this; it is a plain owner (F-11).
@MainActor
final class IDETerminalHostRegistry {
    private struct WeakHost {
        weak var host: IDETerminalHostView?
    }

    private var hosts: [WeakHost] = []

    /// Entries including dead ones. Tests use it to prove registration compacts.
    var count: Int { hosts.count }

    var isEmpty: Bool { hosts.isEmpty }

    func register(_ host: IDETerminalHostView) {
        hosts.removeAll { $0.host == nil }
        hosts.append(WeakHost(host: host))
    }

    /// The terminal shown now, if any.
    func activeHost() -> IDETerminalHostView? {
        hosts.compactMap(\.host).first { $0.isShownActive }
    }

    /// Ends every shell and forgets every host.
    func terminateAll() {
        for entry in hosts {
            entry.host?.terminateProcess()
        }
        hosts.removeAll()
    }
}
