import Foundation

/// Retries 429, 5xx and dropped connections with backoff, honoring `Retry-After`.
public struct RetryPolicy: Sendable {
    public var maxRetries: Int
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval
    public var jitter: Bool

    public static let `default` = RetryPolicy(maxRetries: 4, baseDelay: 1, maxDelay: 30, jitter: true)
    public static let none = RetryPolicy(maxRetries: 0, baseDelay: 0, maxDelay: 0, jitter: false)

    public init(maxRetries: Int, baseDelay: TimeInterval, maxDelay: TimeInterval, jitter: Bool) {
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.jitter = jitter
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
        case is URLError:
            break
        default:
            return nil
        }
        var delay = min(maxDelay, baseDelay * pow(2, Double(attempt)))
        if jitter { delay *= Double.random(in: 0.75...1.0) }
        if let serverDelay { delay = max(delay, min(serverDelay, maxDelay)) }
        return delay
    }
}
