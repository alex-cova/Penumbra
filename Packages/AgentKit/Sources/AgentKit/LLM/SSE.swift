import Foundation

public enum SSEEvent: Sendable, Equatable {
    case data(String)
    case done
}

/// Reads server-sent events one line at a time. OpenAI puts an event's JSON on a single `data:`
/// line, so blank-line event boundaries are not needed (and `AsyncLineSequence` does not deliver
/// blank lines anyway).
public struct SSELineParser: Sendable {
    public init() {}

    public func parse(line: String) -> SSEEvent? {
        // Comments (`:`) are keep-alives. `event:`, `id:` and `retry:` carry nothing the JSON lacks.
        guard line.hasPrefix("data:") else { return nil }
        var payload = line.dropFirst("data:".count)
        if payload.first == " " { payload = payload.dropFirst() }
        if payload == "[DONE]" { return .done }
        return payload.isEmpty ? nil : .data(String(payload))
    }
}
