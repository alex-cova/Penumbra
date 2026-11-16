import Foundation

/// Provider-specific JSON-RPC methods an agent may send to the client (`cursor/ask_question`,
/// `cursor/update_todos`, …).
///
/// `ACPClientSession` consults its extensions only for methods it does not implement itself, so an
/// extension can never change how a standard ACP method behaves. A request no extension claims is
/// answered `-32601 Method not found`; a notification no extension claims is ignored. Either way the
/// agent is never left waiting.
///
/// An extension speaks to the user only through the session (`emitToolCall`, `askQuestion`,
/// `proposePlan`, `emit`), which bounds every wait (Stop, a disconnect, `permissionTimeout`), so a
/// blocking request always gets an answer.
public protocol ACPClientExtension: Sendable {
    /// Whether this extension handles `method`. Cheap and free of side effects.
    func handles(method: String) -> Bool
    /// Answers an agent request. Must return; interactive waits go through the session.
    func handleRequest(method: String, params: JSONValue?, session: ACPClientSession) async -> Result<JSONValue, JSONRPCError>
    /// Handles an agent notification. Runs on the connection's reader, so it must not wait on the user.
    func handleNotification(method: String, params: JSONValue?, session: ACPClientSession) async
}

/// How the user answered a question an extension asked through the session.
public enum ACPQuestionOutcome: Sendable, Equatable {
    case answered(String)
    /// The user dismissed the card (Skip).
    case skipped
    /// Nobody can answer now: Stop, a disconnect, a timeout, or no run on screen.
    case cancelled
}

/// Whether the client starts a login flow on its own when the agent says authentication is needed.
public enum ACPAuthenticationPolicy: Sendable, Equatable {
    /// On `-32000` from `session/new` or `session/load`, authenticate with the first advertised
    /// method and try again. What the Claude Code and Codex adapters have relied on.
    case automatic
    /// Never authenticate unasked. The error goes back to the host, which tells the user how to sign
    /// in (usually the CLI's own login command), or calls `authenticate(methodId:)` when the user asks.
    case userInitiated
}
