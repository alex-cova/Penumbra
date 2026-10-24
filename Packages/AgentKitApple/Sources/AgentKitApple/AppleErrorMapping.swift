import AgentKit
import Foundation
import FoundationModels

/// Turns what the framework throws into what AgentKit's loop understands.
enum AppleErrorMapping {
    enum Outcome {
        /// The model declined; the turn ends normally with this reason.
        case finish(FinishReason)
        case fail(LLMError)
    }

    static let notReady = "Apple Intelligence is still getting its model ready. Try again in a few minutes."
    static let unsupportedLanguage = "Apple's model doesn't support this language or locale."

    static func classify(_ error: Error, hadOutput: Bool) -> Outcome {
        if let error = error as? LLMError { return .fail(error) }
        if #available(macOS 27, *) {
            if let error = error as? LanguageModelError { return classify(error) }
            if let error = error as? PrivateCloudComputeLanguageModel.Error { return classify(error, hadOutput: hadOutput) }
            if let error = error as? SystemLanguageModel.Error { return .fail(.api(message: error.localizedDescription, code: nil)) }
        }
        if let error = error as? LanguageModelSession.GenerationError { return classify(error) }
        if let error = error as? LanguageModelSession.ToolCallError {
            return classify(error.underlyingError, hadOutput: hadOutput)
        }
        return .fail(.api(message: describe(error), code: nil))
    }

    /// The framework's own errors often arrive as an `NSError` whose description is "error -1" and whose
    /// cause is in the underlying errors, so the innermost one is named.
    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var innermost = ns
        while let next = (innermost.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError])?.first
            ?? innermost.userInfo[NSUnderlyingErrorKey] as? NSError {
            innermost = next
        }
        guard innermost !== ns else { return error.localizedDescription }
        return "Apple's model could not answer (\(innermost.domain) \(innermost.code))."
    }

    @available(macOS 27, *)
    private static func classify(_ error: LanguageModelError) -> Outcome {
        switch error {
        case .contextSizeExceeded: .fail(.contextLengthExceeded)
        case .rateLimited: .fail(.rateLimited(retryAfter: nil))
        case .guardrailViolation, .refusal: .finish(.contentFilter)
        case .unsupportedLanguageOrLocale: .fail(.api(message: unsupportedLanguage, code: nil))
        default: .fail(.api(message: describe(error), code: nil))
        }
    }

    @available(macOS 27, *)
    private static func classify(_ error: PrivateCloudComputeLanguageModel.Error, hadOutput: Bool) -> Outcome {
        switch error {
        case .networkFailure(let failure):
            .fail(hadOutput ? .interruptedAfterOutput(failure.debugDescription) : .connectionLost(failure.debugDescription))
        case .quotaLimitReached(let quota):
            .fail(.rateLimited(retryAfter: quota.resetDate.map { max(0, $0.timeIntervalSinceNow) }))
        case .serviceUnavailable:
            .fail(.server(status: 503, message: error.localizedDescription))
        @unknown default:
            .fail(.api(message: error.localizedDescription, code: nil))
        }
    }

    private static func classify(_ error: LanguageModelSession.GenerationError) -> Outcome {
        switch error {
        case .exceededContextWindowSize: .fail(.contextLengthExceeded)
        case .assetsUnavailable: .fail(.api(message: notReady, code: nil))
        case .guardrailViolation, .refusal: .finish(.contentFilter)
        case .unsupportedLanguageOrLocale: .fail(.api(message: unsupportedLanguage, code: nil))
        case .rateLimited: .fail(.rateLimited(retryAfter: nil))
        default: .fail(.api(message: describe(error), code: nil))
        }
    }
}
