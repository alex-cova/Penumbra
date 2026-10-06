import Foundation

public struct SubprocessExit: Sendable, Equatable {
    /// `nil` when the child was killed by a signal.
    public var exitCode: Int32?
    public var signal: Int32?

    public init(exitCode: Int32?, signal: Int32?) {
        self.exitCode = exitCode
        self.signal = signal
    }

    public var succeeded: Bool { exitCode == 0 }

    /// The exit code, else the signal number: the single number a shell-style caller reports.
    public var status: Int32 { exitCode ?? signal ?? -1 }
}

public enum SubprocessOutputSource: Sendable, Equatable {
    case stdout
    case stderr
}

/// A non-zero exit, a signal, a timeout and a cancellation are all results: only failing to start
/// throws (`SubprocessError`).
public struct SubprocessResult: Sendable {
    public var exit: SubprocessExit
    /// With `.merged` output, both streams are here and `stderr` is empty.
    public var stdout: CapturedOutput
    public var stderr: CapturedOutput
    public var timedOut: Bool
    public var cancelled: Bool
    public var duration: TimeInterval

    public init(
        exit: SubprocessExit, stdout: CapturedOutput, stderr: CapturedOutput,
        timedOut: Bool, cancelled: Bool, duration: TimeInterval
    ) {
        self.exit = exit
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.cancelled = cancelled
        self.duration = duration
    }
}
