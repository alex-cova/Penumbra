import Foundation

/// What to run and how. A request describes one child process: nothing here is shared between runs.
public struct SubprocessRequest: Sendable {
    /// Absolute path of the program. `argv[0]` is this path.
    public var executable: String
    /// The arguments after the program name.
    public var arguments: [String]
    public var workingDirectory: URL?
    /// The child's whole environment. `nil` inherits this process's.
    public var environment: [String: String]?

    public enum StandardInput: Sendable {
        /// `/dev/null`. The default: a child that reads stdin sees EOF at once instead of
        /// waiting on a terminal that nothing will ever type into.
        case closed
        /// Written to the child, then closed. A child that stops reading early is not an error.
        case data(Data)
        /// A pipe that stays open: only `SubprocessRunner.start` can write to it (through the
        /// handle it returns), and the child sees end of input at `closeInput()` or when it exits.
        /// With `run` or `runBlocking` nothing writes, so the child waits for input that never comes.
        case interactive
    }
    public var standardInput: StandardInput = .closed

    public enum OutputRouting: Sendable {
        case separateStreams
        /// stderr goes down the stdout pipe, so the two arrive interleaved in order.
        case merged
    }
    public var output: OutputRouting = .separateStreams

    /// What is kept of each stream. With `.merged` everything is in `stdoutCapture`.
    public var stdoutCapture: OutputCapture = .all
    public var stderrCapture: OutputCapture = .all

    /// Start the child as the leader of its own process group, and signal the group (not just the
    /// leader) on timeout or cancellation.
    public var processGroup: Bool = false
    /// After the leader exits, signal what it left in its group. Needs `processGroup`. Right for a
    /// shell (nothing it started may outlive it), wrong for a tool that leaves a daemon on purpose.
    public var killGroupOnExit: Bool = false

    /// `nil` runs until the child exits.
    public var timeout: Duration?
    /// On timeout or cancellation: SIGTERM, then SIGKILL this much later. Zero sends SIGKILL at once.
    public var terminationGrace: Duration = .seconds(2)

    public init(executable: String, arguments: [String] = []) {
        self.executable = executable
        self.arguments = arguments
    }
}
