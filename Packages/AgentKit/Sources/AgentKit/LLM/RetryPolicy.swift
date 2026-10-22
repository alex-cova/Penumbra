import Foundation

/// Retries 429, 5xx and dropped connections with backoff, honoring `Retry-After`.
public struct RetryPolicy: Sendable {
    public var maxRetries: Int
    public var baseDelay: TimeInterval
    /// Cap on the backoff between two tries.
    public var maxDelay: TimeInterval
    public var jitter: Bool
    /// Cap on a delay the server asked for (`Retry-After`). `nil` uses `maxDelay`. A provider that
    /// says "come back in 60 s" is not helped by a retry after 30.
    public var maxServerDelay: TimeInterval?
    /// A request that timed out already waited a long time, so it is retried only for the first
    /// `maxTimeoutRetries` tries.
    public var maxTimeoutRetries: Int

    /// Eight tries, 2 s doubling to 20 s, so a failing provider is given about two minutes; a
    /// server-supplied delay is honored up to five minutes.
    public static let `default` = RetryPolicy(
        maxRetries: 8, baseDelay: 2, maxDelay: 20, jitter: true, maxServerDelay: 300, maxTimeoutRetries: 3)
    public static let none = RetryPolicy(maxRetries: 0, baseDelay: 0, maxDelay: 0, jitter: false)

    public init(
        maxRetries: Int, baseDelay: TimeInterval, maxDelay: TimeInterval, jitter: Bool,
        maxServerDelay: TimeInterval? = nil, maxTimeoutRetries: Int = .max
    ) {
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.jitter = jitter
        self.maxServerDelay = maxServerDelay
        self.maxTimeoutRetries = maxTimeoutRetries
    }

    /// Seconds to wait before retry number `attempt` (0-based), or `nil` when the error is final.
    public func delay(for error: Error, attempt: Int) -> TimeInterval? {
        guard attempt < maxRetries else { return nil }
        var serverDelay: TimeInterval?
        switch error {
        case let error as LLMError:
            switch error {
            case .rateLimited(let retryAfter): serverDelay = retryAfter
            case .server, .connectionLost: break
            default: return nil
            }
        case let error as URLError:
            if error.code == .timedOut, attempt >= maxTimeoutRetries { return nil }
        default:
            return nil
        }
        var delay = min(maxDelay, baseDelay * pow(2, Double(attempt)))
        if jitter { delay *= Double.random(in: 0.75...1.0) }
        if let serverDelay { delay = max(delay, min(serverDelay, maxServerDelay ?? maxDelay)) }
        return delay
    }
}
