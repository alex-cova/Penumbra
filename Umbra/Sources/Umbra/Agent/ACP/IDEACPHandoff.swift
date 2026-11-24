import AgentKit
import Foundation

/// The transcript an external agent did not see, as the turns of a `ConversationHandoff`
/// (`docs/harness/agent-harness-10.md`). What the user typed and what the agent answered are kept;
/// a run of tool calls becomes one activity line; notices, errors and change summaries are left out.
enum IDEACPHandoff {
    static func turns(from entries: some Sequence<IDEAgentEntry>) -> [HandoffTurn] {
        var turns: [HandoffTurn] = []
        var tools: [(name: String, count: Int, failed: Bool)] = []

        func flushTools() {
            guard !tools.isEmpty else { return }
            let names = tools.map { tool in
                (tool.count > 1 ? "\(tool.name) ×\(tool.count)" : tool.name) + (tool.failed ? " (failed)" : "")
            }
            turns.append(HandoffTurn(role: .activity, text: "Used tools: " + names.joined(separator: ", ")))
            tools = []
        }

        for entry in entries {
            switch entry.kind {
            case .user:
                flushTools()
                turns.append(HandoffTurn(role: .user, text: entry.text))
            case .assistant:
                flushTools()
                turns.append(HandoffTurn(role: .assistant, text: entry.text))
            case .toolCall(let name):
                let failed = entry.output?.isError == true
                if let last = tools.last, last.name == name, last.failed == failed {
                    tools[tools.count - 1].count += 1
                } else {
                    tools.append((name, 1, failed))
                }
            case .notice, .error, .changes:
                continue
            }
        }
        flushTools()
        return turns
    }

    /// The notice at the top of the chat a switch of agents opened.
    static func switchNotice(next: String, previous: String, title: String?, carries: Bool) -> String {
        guard carries else { return "This chat uses \(next). \(previous) stays in its own chat." }
        let source = title.map { "“\($0)”" } ?? "the previous chat"
        return "This chat uses \(next) and continues \(source). Your first message brings that conversation with it. \(previous) stays in its own chat."
    }

    /// What to tell the user when not every earlier message fit.
    static func partialNotice(_ handoff: ConversationHandoff) -> String? {
        guard handoff.omittedCount > 0 else { return nil }
        return "Sent the last \(handoff.sentCount) of \(handoff.totalCount) earlier messages to the new session. Older ones were left out to fit."
    }
}
