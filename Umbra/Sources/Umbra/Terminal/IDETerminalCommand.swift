/// The command belongs to the tab, whose host view can be recreated when the bottom panel reopens.
@MainActor
final class IDETerminalCommand: Equatable {
    let launch: IDETerminalLaunch
    var hasLaunched = false

    init(_ launch: IDETerminalLaunch) {
        self.launch = launch
    }

    nonisolated static func == (lhs: IDETerminalCommand, rhs: IDETerminalCommand) -> Bool {
        lhs === rhs
    }
}
