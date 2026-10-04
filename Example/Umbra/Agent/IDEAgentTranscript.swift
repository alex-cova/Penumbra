import AgentKit
import Foundation

/// One row of the panel's transcript.
struct IDEAgentEntry: Identifiable, Equatable {
    enum Kind: Equatable {
        case user
        case assistant
        case toolCall(name: String)
        case notice
        case error
        /// "N files changed" for one run, with Show Diff and Revert Run.
        case changes
    }

    let id = UUID()
    var kind: Kind
    /// The message text, or a tool call's arguments as JSON.
    var text: String
    /// Set for tool calls once the call finishes.
    var callID: String?
    var output: ToolOutput?
    /// Still receiving text; shown plain until it completes, then rendered as Markdown.
    var isStreaming = false
    /// For `.changes`: the run, the files it changed, and what Revert did not touch.
    var run: RunID?
    var fileChanges: [IDEAgentFileChange] = []
    var conflicts: [IDEAgentFileChange] = []
    var isReverted = false
    /// For a tool call waiting on the user: what is being asked.
    var approval: ApprovalRequest?
    /// For `ask_user`: the question waiting for an answer, and the answer once given ("Skipped" if dismissed).
    var question: UserQuestion?
    var questionOutcome: String?
    /// What the user chose, once they did: "Approved", "Edited and approved" or "Denied".
    var approvalOutcome: String?
    /// A command's output as it arrives; the card shows it in full while the model gets a summary.
    var liveOutput = ""

    var isFinishedToolCall: Bool { output != nil }
}

/// A command's live output, kept to the most recent part so a chatty build can't grow the transcript
/// without bound.
enum IDEAgentLiveOutput {
    static let limit = 200_000

    static func append(_ existing: String, _ chunk: String, limit: Int = limit) -> String {
        let combined = existing + chunk
        guard combined.count > limit else { return combined }
        let kept = combined.suffix(limit)
        // Start on a whole line, and say that the start is gone.
        let body = kept.firstIndex(of: "\n").map { kept[kept.index(after: $0)...] } ?? kept
        return "[… earlier output not shown …]\n" + body
    }
}

/// A file a run changed. `original` is the text before the run (`nil`: the run created the file).
struct IDEAgentFileChange: Equatable, Identifiable {
    var path: String
    var original: String?

    var id: String { path }
    var isCreation: Bool { original == nil }
}

/// One-line titles for tool-call cards, built from the arguments the model sent.
enum IDEAgentToolSummary {
    static func title(name: String, arguments: String) -> String {
        guard let object = (try? JSONValue(parsing: arguments))?.objectValue else { return name }
        let detail: String? = switch name {
        case "read_file":
            [object["path"]?.stringValue, lineRange(object)].compactMap { $0 }.joined(separator: " ")
        case "list_dir": object["path"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "."
        case "glob": object["pattern"]?.stringValue
        case "grep": object["pattern"]?.stringValue.map { "“\($0)”" }
        case "diagnostics", "edit_file", "write_file": object["path"]?.stringValue
        case "ask_user": object["question"]?.stringValue
        case "todo": object["items"]?.arrayValue.map { "\($0.count) \($0.count == 1 ? "item" : "items")" }
        case "run_command": object["command"]?.stringValue
        case "gradle": object["tasks"]?.arrayValue?.compactMap(\.stringValue).joined(separator: " ")
        case "run_tests":
            ((object["module"]?.stringValue.map { [$0] } ?? [])
                + (object["tests"]?.arrayValue?.compactMap(\.stringValue) ?? [])).joined(separator: " ")
        default: nil
        }
        guard let detail, !detail.isEmpty else { return name }
        return "\(name)  \(detail)"
    }

    private static func lineRange(_ object: [String: JSONValue]) -> String? {
        guard let offset = object["offset"]?.intValue else { return nil }
        if let limit = object["limit"]?.intValue { return ":\(offset)–\(offset + limit - 1)" }
        return ":\(offset)"
    }

    static func endingMessage(_ ending: RunEnding, iterationLimit: Int) -> (text: String, isError: Bool)? {
        switch ending {
        case .completed: nil
        case .stopped: ("Stopped.", false)
        case .lengthLimit: ("The model reached its output limit. Send “continue” to go on.", false)
        case .contentFiltered: ("The response was blocked by the provider's content filter.", true)
        case .iterationCap: ("Paused after \(iterationLimit) steps. Send “continue” to go on.", false)
        case .repeatedCall(let name): ("Stopped: the model kept repeating the same \(name) call.", true)
        case .failed(let message): (message, true)
        }
    }
}
