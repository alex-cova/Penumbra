import Foundation

/// What a provider says is left of its rate limit, from the `x-ratelimit-*` response headers
/// (Meta's Model API sends all four; OpenAI sends the same names). A host shows it when a request
/// has to wait, so "the provider is busy" can say which limit ran out. The window is the provider's
/// (Meta: per minute, per team), not something the headers name.
public struct RateLimitStatus: Sendable, Hashable {
    public var limitRequests: Int?
    public var remainingRequests: Int?
    public var limitTokens: Int?
    public var remainingTokens: Int?

    public init(limitRequests: Int? = nil, remainingRequests: Int? = nil, limitTokens: Int? = nil, remainingTokens: Int? = nil) {
        self.limitRequests = limitRequests
        self.remainingRequests = remainingRequests
        self.limitTokens = limitTokens
        self.remainingTokens = remainingTokens
    }

    /// `nil` when the response carries none of the four headers. Header names are matched without
    /// regard to case.
    public static func parse(headers: [String: String]) -> RateLimitStatus? {
        let lowered = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        func number(_ name: String) -> Int? { lowered[name].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
        let status = RateLimitStatus(
            limitRequests: number("x-ratelimit-limit-requests"), remainingRequests: number("x-ratelimit-remaining-requests"),
            limitTokens: number("x-ratelimit-limit-tokens"), remainingTokens: number("x-ratelimit-remaining-tokens"))
        return status == RateLimitStatus() ? nil : status
    }

    /// The limit that has run out ("requests" or "tokens"), if either has.
    public var exhausted: String? {
        if let remaining = remainingRequests, remaining <= 0 { return "requests" }
        if let remaining = remainingTokens, remaining <= 0 { return "tokens" }
        return nil
    }
}
