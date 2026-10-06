import Foundation

/// Failing to start a child. Everything that happens after it started is a `SubprocessResult`.
public enum SubprocessError: Error, Sendable, Equatable, LocalizedError {
    /// `posix_spawn` refused: a missing or non-executable program, a missing working directory.
    case launchFailed(errno: Int32)
    case pipeFailed(errno: Int32)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let code): "The process could not be started: \(String(cString: strerror(code)))."
        case .pipeFailed(let code): "A pipe for the process could not be created: \(String(cString: strerror(code)))."
        }
    }
}
