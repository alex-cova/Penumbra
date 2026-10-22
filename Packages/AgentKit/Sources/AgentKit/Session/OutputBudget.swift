import Foundation

/// How many tokens a response may ask for. A request that asks for more than the window has room for
/// is rejected (or silently shortened) by the provider, and the room shrinks as the conversation grows.
enum OutputBudget {
    /// Never ask for less than this: a response needs room to say something.
    static let minimumTokens = 1_024
    /// What a request with no limit of its own is assumed to want (Anthropic's default here).
    static let ceiling = 32_000
    /// The estimate of tokens not yet measured by the provider can run low on dense text such as code.
    static let estimateError = 0.15

    /// `requested` unchanged when the window leaves room for it (and `nil` stays `nil`, so the provider's
    /// own default applies); otherwise what the window leaves, never below `minimumTokens`.
    /// `measured` is what the provider reported for the prompt, `estimated` the tokens added since
    /// (or the whole prompt, before the first report); only the estimate gets the error margin.
    static func maxOutputTokens(
        requested: Int?, ceiling: Int = ceiling, window: Int?, measured: Int, estimated: Int
    ) -> Int? {
        guard let window, window > 0 else { return requested }
        let padded = Int((Double(estimated) * (1 + estimateError)).rounded(.up))
        let room = window - measured - padded
        guard room < (requested ?? ceiling) else { return requested }
        let fitted = max(minimumTokens, room)
        return requested.map { min($0, fitted) } ?? fitted
    }
}
