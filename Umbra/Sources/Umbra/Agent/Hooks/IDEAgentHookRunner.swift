import AgentKit
import Foundation
import SubprocessKit

/// Runs a hook's shell command and maps the result onto what the session does with it.
/// Stdin carries `{session_id, cwd, hook_event_name, tool_name, tool_input, tool_response?}`.
/// Exit 0 continues (stdout is added context for after-hooks); exit 2 blocks and stderr goes
/// to the model; any other failure warns and fails open, unless the hook is required.
nonisolated enum IDEAgentHookRunner {
    static let defaultTimeout: TimeInterval = 30
    static let maxStdoutCharacters = 8_000
    static let maxStderrCharacters = 4_000

    struct Outcome: Sendable, Equatable {
        var exitCode: Int32?
        var stdout: String
        var stderr: String
        var timedOut: Bool
        var started: Bool
    }

    static func run(
        entry: IDEAgentHookEntry, stdin: Data, workingDirectory: URL, environment: [String: String]
    ) async -> Outcome {
        var request = SubprocessRequest(executable: "/bin/zsh", arguments: ["-c", entry.command])
        request.workingDirectory = workingDirectory
        request.environment = environment
        request.standardInput = .data(stdin)
        request.output = .separateStreams
        request.stdoutCapture = .bounded(head: 64 * 1_024, tail: 64 * 1_024)
        request.stderrCapture = .bounded(head: 16 * 1_024, tail: 16 * 1_024)
        request.processGroup = true
        request.killGroupOnExit = true
        request.timeout = .seconds(entry.timeout)
        request.terminationGrace = .seconds(2)
        let result: SubprocessResult
        do {
            result = try await SubprocessRunner.run(request)
        } catch {
            return Outcome(exitCode: nil, stdout: "", stderr: "", timedOut: false, started: false)
        }
        return Outcome(
            exitCode: result.exit.exitCode,
            stdout: OutputTruncation.headAndTail(result.stdout.text, maxCharacters: maxStdoutCharacters),
            stderr: OutputTruncation.headAndTail(result.stderr.text, maxCharacters: maxStderrCharacters),
            timedOut: result.timedOut, started: true)
    }

    /// The stdin JSON for a tool hook. `tool_input` is the call's arguments as an object when
    /// they parse, else the raw text; `tool_response` is the call's output (after-hooks only).
    static func stdinJSON(
        sessionID: String, root: URL, event: IDEAgentHookEvent,
        toolName: String? = nil, argumentsJSON: String? = nil, output: String? = nil
    ) -> Data {
        var object: [String: Any] = [
            "session_id": sessionID, "cwd": root.path, "hook_event_name": event.rawValue,
        ]
        if let toolName { object["tool_name"] = toolName }
        if let argumentsJSON {
            if let data = argumentsJSON.data(using: .utf8),
               let value = try? JSONSerialization.jsonObject(with: data) {
                object["tool_input"] = value
            } else {
                object["tool_input"] = argumentsJSON
            }
        }
        if let output { object["tool_response"] = output }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// What a before-hook's outcome means. Deny reasons are wrapped as untrusted content: the
    /// hook wrote them, the user did not.
    static func preDecision(
        _ outcome: Outcome, entry: IDEAgentHookEntry, warn: (String) -> Void
    ) -> HookDecision {
        if let failure = startFailure(of: outcome, entry: entry, warn: warn) { return failure }
        switch outcome.exitCode {
        case 0:
            return .allow
        case 2:
            let reason = outcome.stderr.isEmpty ? "A hook blocked this call." : outcome.stderr
            return .deny(UntrustedContent.wrap(reason, source: "hook"))
        default:
            if entry.required {
                return .deny(UntrustedContent.wrap(
                    "Hook \"\(entry.command)\" exited with status \(status(of: outcome)).", source: "hook"))
            }
            warn("Hook \"\(entry.command)\" exited with status \(status(of: outcome)), so it was skipped.")
            return .allow
        }
    }

    /// Context a passing after-hook adds to the call's output for the model, or `nil` when the
    /// hook says nothing (exit 0 with no stdout) or fails open.
    static func postText(
        _ outcome: Outcome, entry: IDEAgentHookEntry, warn: (String) -> Void
    ) -> String? {
        if !outcome.started || outcome.timedOut {
            if entry.required {
                return UntrustedContent.wrap(failureNote(of: outcome, entry: entry), source: "hook")
            }
            warn("Hook \"\(entry.command)\" \(shortFailure(of: outcome)), so it was skipped.")
            return nil
        }
        switch outcome.exitCode {
        case 0:
            return outcome.stdout.isEmpty ? nil : UntrustedContent.wrap(outcome.stdout, source: "hook")
        case 2:
            let text = [outcome.stdout, outcome.stderr].filter { !$0.isEmpty }.joined(separator: "\n\n")
            return UntrustedContent.wrap(
                text.isEmpty ? "A hook reported a problem." : text, source: "hook")
        default:
            if entry.required {
                return UntrustedContent.wrap(
                    "Hook \"\(entry.command)\" exited with status \(status(of: outcome))."
                        + (outcome.stderr.isEmpty ? "" : "\n\n" + outcome.stderr),
                    source: "hook")
            }
            warn("Hook \"\(entry.command)\" exited with status \(status(of: outcome)), so it was skipped.")
            return nil
        }
    }

    /// What a Stop hook's outcome means for the run. A failure throws so the policy fails open,
    /// unless the hook is required.
    static func stopVerdict(_ outcome: Outcome, entry: IDEAgentHookEntry) throws -> StopGateVerdict {
        if !outcome.started || outcome.timedOut { throw HookRunError.notRun(shortFailure(of: outcome)) }
        switch outcome.exitCode {
        case 0:
            return .pass
        case 2:
            let reason = outcome.stderr.isEmpty ? "A Stop hook blocked the run." : outcome.stderr
            return .block(reason: UntrustedContent.wrap(reason, source: "hook"))
        default:
            if entry.required {
                return .block(reason: UntrustedContent.wrap(
                    "Hook \"\(entry.command)\" exited with status \(status(of: outcome)).", source: "hook"))
            }
            throw HookRunError.notRun("exited with status \(status(of: outcome))")
        }
    }

    private static func startFailure(
        of outcome: Outcome, entry: IDEAgentHookEntry, warn: (String) -> Void
    ) -> HookDecision? {
        guard !outcome.started || outcome.timedOut else { return nil }
        if entry.required { return .deny(UntrustedContent.wrap(failureNote(of: outcome, entry: entry), source: "hook")) }
        warn("Hook \"\(entry.command)\" \(shortFailure(of: outcome)), so it was skipped.")
        return .allow
    }

    private static func failureNote(of outcome: Outcome, entry: IDEAgentHookEntry) -> String {
        "Hook \"\(entry.command)\" \(shortFailure(of: outcome))."
    }

    private static func shortFailure(of outcome: Outcome) -> String {
        if !outcome.started { return "could not start" }
        return "timed out"
    }

    private static func status(of outcome: Outcome) -> String {
        if outcome.timedOut { return "a timeout" }
        if let code = outcome.exitCode { return "code \(code)" }
        return "a signal"
    }
}

enum HookRunError: Error, LocalizedError {
    case notRun(String)

    var errorDescription: String? {
        if case .notRun(let detail) = self { return "The hook \(detail)." }
        return nil
    }
}

/// The host side of `ToolHooks`: matches the agent's tool calls against the configured shell
/// hooks and runs them in the project. Applies to the agent's tool calls only — never to the
/// user's own edits or commands — and a child session gets the same hooks through AgentKit.
final class IDEAgentHookHost: ToolHooks, @unchecked Sendable {
    struct Context: Sendable {
        var sessionID: String
        var root: URL
        var environment: [String: String]
        var onWarning: @Sendable (String) -> Void
    }

    private let preHooks: [IDEAgentHookEntry]
    private let postHooks: [IDEAgentHookEntry]
    private let context: Context

    init(entries: [IDEAgentHookEntry], context: Context) {
        preHooks = entries.filter { $0.event == .preToolUse }
        postHooks = entries.filter { $0.event == .postToolUse }
        self.context = context
    }

    func before(_ call: HookCall) async -> HookDecision {
        var ask = false
        for entry in preHooks where entry.matches(toolName: call.toolName) {
            let outcome = await IDEAgentHookRunner.run(
                entry: entry, stdin: stdin(event: .preToolUse, call: call),
                workingDirectory: context.root, environment: context.environment)
            switch IDEAgentHookRunner.preDecision(outcome, entry: entry, warn: context.onWarning) {
            case .allow:
                break
            case .deny(let reason):
                return .deny(reason)
            case .ask:
                ask = true
            }
        }
        return ask ? .ask : .allow
    }

    func after(_ call: HookCall, output: String) async -> String? {
        var pieces: [String] = []
        for entry in postHooks where entry.matches(toolName: call.toolName) {
            let outcome = await IDEAgentHookRunner.run(
                entry: entry, stdin: stdin(event: .postToolUse, call: call, output: output),
                workingDirectory: context.root, environment: context.environment)
            if let text = IDEAgentHookRunner.postText(outcome, entry: entry, warn: context.onWarning) {
                pieces.append(text)
            }
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: "\n\n")
    }

    /// The check for a `HookStopPolicy`, built from the configured Stop hooks.
    static func stopCheck(entries: [IDEAgentHookEntry], context: Context) -> @Sendable (StopGateInput) async throws -> StopGateVerdict {
        let stops = entries.filter { $0.event == .stop }
        return { input in
            for entry in stops where entry.matcher.isEmpty || entry.matches(toolName: "") {
                let object: [String: Any] = [
                    "session_id": context.sessionID, "cwd": context.root.path,
                    "hook_event_name": IDEAgentHookEvent.stop.rawValue,
                    "stop_hook_active": input.continuations > 0,
                    "files_edited": input.filesEdited,
                    "last_assistant_text": input.lastAssistantText,
                ]
                let stdin = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
                let outcome = await IDEAgentHookRunner.run(
                    entry: entry, stdin: stdin,
                    workingDirectory: context.root, environment: context.environment)
                let verdict = try IDEAgentHookRunner.stopVerdict(outcome, entry: entry)
                if case .block = verdict { return verdict }
            }
            return .pass
        }
    }

    private func stdin(event: IDEAgentHookEvent, call: HookCall, output: String? = nil) -> Data {
        IDEAgentHookRunner.stdinJSON(
            sessionID: context.sessionID, root: context.root, event: event,
            toolName: call.toolName, argumentsJSON: call.argumentsJSON, output: output)
    }
}
