import Foundation

/// Maps a non-2xx response to an `LLMError`, shared by every HTTP client.
public enum HTTPErrorClassifier {
    public static func classify(status: Int, body: String, retryAfter: TimeInterval?) -> LLMError {
        let message = errorMessage(in: body) ?? String(body.prefix(500))
        let lowered = (message + " " + body).lowercased()
        switch status {
        case 401:
            return .unauthorized
        case 429:
            // A spent quota won't recover by waiting.
            if lowered.contains("insufficient_quota") { return .api(message: message, code: "insufficient_quota") }
            return .rateLimited(retryAfter: retryAfter)
        case 500...599:
            return .server(status: status, message: message)
        case 400 where lowered.contains("context_length_exceeded") || lowered.contains("maximum context length"):
            return .contextLengthExceeded
        default:
            return .badRequest(status: status, message: message)
        }
    }

    /// `Retry-After` in seconds. The HTTP-date form is ignored; backoff covers it.
    public static func retryAfter(from headers: [String: String]) -> TimeInterval? {
        headers["retry-after"].flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
    }

    private static func errorMessage(in body: String) -> String? {
        guard let json = try? JSONValue(parsing: body) else { return nil }
        // OpenAI nests it (`error.message`); Ollama sends `{"error": "text"}`.
        return json["error"]?["message"]?.stringValue ?? json["error"]?.stringValue ?? json["message"]?.stringValue
    }
}
