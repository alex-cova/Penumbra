import Foundation

/// When and how a conversation is shortened so a long run keeps fitting the model's window.
public struct CompactionPolicy: Sendable, Equatable {
    public var contextWindow: Int
    /// Compact when the estimated context passes this share of the window.
    public var threshold: Double
    /// Stubbing aims to get back down to this share.
    public var target: Double
    /// The newest tool outputs are never stubbed: the model is probably still working from them.
    public var keepRecentToolOutputs: Int
    /// An output smaller than this is not worth replacing.
    public var minimumStubbableBytes: Int
    /// A summary keeps this many of the newest model turns word for word.
    public var keepRecentTurns: Int

    public init(
        contextWindow: Int, threshold: Double = 0.75, target: Double = 0.5,
        keepRecentToolOutputs: Int = 4, minimumStubbableBytes: Int = 600, keepRecentTurns: Int = 2
    ) {
        self.contextWindow = contextWindow
        self.threshold = threshold
        self.target = target
        self.keepRecentToolOutputs = keepRecentToolOutputs
        self.minimumStubbableBytes = minimumStubbableBytes
        self.keepRecentTurns = keepRecentTurns
    }
}

public struct CompactionReport: Sendable, Equatable {
    public var stubbedOutputs = 0
    public var summarizedItems = 0
    public var estimatedTokensBefore = 0
    public var estimatedTokensAfter = 0
    /// A summary was needed but the model could not write one; the stubs alone were applied.
    public var summaryFailed = false

    public init() {}

    public var changedAnything: Bool { stubbedOutputs > 0 || summarizedItems > 0 }
}

/// Token counts without a tokenizer: UTF-8 bytes divided by four. Close enough to decide when to
/// compact, and the same on every provider.
public enum ContextBudget {
    public static func tokens(forBytes bytes: Int) -> Int { (bytes + 3) / 4 }
    public static func tokens(_ text: String) -> Int { tokens(forBytes: text.utf8.count) }

    public static func tokens(_ item: ConversationItem) -> Int {
        switch item {
        case .user(let text), .assistant(let text): tokens(text) + 4
        case .toolCall(let id, let name, let arguments): tokens(id) + tokens(name) + tokens(arguments) + 8
        case .toolOutput(let callID, let output): tokens(callID) + tokens(output) + 4
        case .opaque(let item): tokens((try? item.payload.serialized()) ?? "")
        }
    }

    public static func tokens(_ items: some Sequence<ConversationItem>) -> Int {
        items.reduce(0) { $0 + tokens($1) }
    }

    /// The part of every request that is not the conversation.
    public static func tokens(system: String, tools: [ToolDefinition]) -> Int {
        tokens(system) + tools.reduce(0) { total, tool in
            total + tokens(tool.name) + tokens(tool.description) + tokens((try? tool.schema(strict: false).serialized()) ?? "")
        }
    }
}

/// Stage one of compaction: tool outputs are the bulk of a long coding session, and the model can
/// ask for any of them again, so the old ones become a line saying what they were.
public enum ToolOutputStubs {
    public static let marker = "output elided to save context"

    public static func isStub(_ output: String) -> Bool { output.hasPrefix("[") && output.contains(marker) }

    /// Replaces the oldest large outputs, in one pass, until the estimate reaches the target. Returns the
    /// new items and how many were replaced. Doing it in one batch breaks the provider's cached
    /// prefix once, instead of a little more on every turn.
    public static func apply(to items: [ConversationItem], policy: CompactionPolicy, estimatedTokens: Int) -> (items: [ConversationItem], stubbed: Int) {
        let outputs = items.indices.filter { if case .toolOutput = items[$0] { true } else { false } }
        let candidates = outputs.dropLast(policy.keepRecentToolOutputs)
        var needed = estimatedTokens - Int(Double(policy.contextWindow) * policy.target)
        guard needed > 0, !candidates.isEmpty else { return (items, 0) }

        var result = items
        var stubbed = 0
        for index in candidates {
            guard needed > 0, case .toolOutput(let callID, let output) = items[index],
                  output.utf8.count >= policy.minimumStubbableBytes, !isStub(output)
            else { continue }
            let stub = describe(callID: callID, output: output, in: items, before: index)
            guard stub.utf8.count < output.utf8.count else { continue }
            needed -= ContextBudget.tokens(output) - ContextBudget.tokens(stub)
            result[index] = .toolOutput(callID: callID, output: stub)
            stubbed += 1
        }
        return (result, stubbed)
    }

    /// `[read_file src/A.java lines 1–200: output elided to save context (200 lines). Call it again if you need it.]`
    static func describe(callID: String, output: String, in items: [ConversationItem], before index: Int) -> String {
        var what = "tool output"
        for item in items[..<index].reversed() {
            if case .toolCall(let id, let name, let arguments) = item, id == callID {
                what = [name, argumentSummary(arguments)].filter { !$0.isEmpty }.joined(separator: " ")
                break
            }
        }
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).count
        return "[\(what): \(marker) (\(lines) lines). Call it again if you need it.]"
    }

    private static func argumentSummary(_ arguments: String) -> String {
        guard let object = (try? JSONValue(parsing: arguments))?.objectValue else { return "" }
        var parts: [String] = []
        for key in ["path", "pattern", "command", "tasks", "tests", "module"] {
            guard let value = object[key] else { continue }
            let text: String
            switch value {
            case .string(let string): text = string
            case .array(let items): text = items.compactMap(\.stringValue).joined(separator: " ")
            default: continue
            }
            if !text.isEmpty { parts.append(text.count > 80 ? String(text.prefix(80)) + "…" : text) }
        }
        if let offset = object["offset"]?.intValue {
            let end = object["limit"]?.intValue.map { offset + $0 - 1 }
            parts.append("lines \(offset)–\(end.map(String.init) ?? "…")")
        }
        return parts.joined(separator: " ")
    }
}

/// Stage two: when stubs are not enough, the oldest part of the conversation becomes one model-written
/// summary. The cut always falls where a model turn begins, so a tool call is never separated from
/// its output.
public enum ConversationSummary {
    public static let systemPrompt = """
    You compress the history of a coding-agent session so the agent can keep working from the summary. \
    Write a concise summary: what the user asked for, what has been done (files read or changed, with \
    their paths), what was found, decisions made, errors and how they were handled, and what is still \
    to do. Keep identifiers, paths, commands and error messages exact. Write plain text, no preamble.
    """

    public static let heading = "[Summary of the earlier conversation, written by the assistant to save space. The user did not write it.]"

    /// The index where the retained tail begins, or `nil` if there is nothing worth summarizing.
    /// The tail starts at a user message or at the start of a model turn, and holds at least
    /// `keepTurns` model turns.
    public static func cutIndex(in items: [ConversationItem], keepTurns: Int) -> Int? {
        var starts: [Int] = []
        for (index, item) in items.enumerated() {
            let previous = index > 0 ? items[index - 1] : nil
            switch item {
            case .user:
                starts.append(index)
            case .assistant, .toolCall, .opaque:
                // A turn begins after a user message or after tool outputs, never in the middle of its own calls.
                switch previous {
                case nil, .user?, .toolOutput?: starts.append(index)
                default: break
                }
            case .toolOutput:
                break
            }
        }
        let modelTurns = starts.filter { if case .user = items[$0] { false } else { true } }
        guard modelTurns.count > keepTurns else {
            // Few turns: cut at the last user message, if there is an earlier one to summarize.
            let users = starts.filter { if case .user = items[$0] { true } else { false } }
            return users.count > 1 ? users.last : nil
        }
        let cut = modelTurns[modelTurns.count - keepTurns]
        return cut > 0 ? cut : nil
    }

    /// The older items as plain text, each tool output cut short, for the summarizing request.
    public static func transcript(of items: [ConversationItem], perOutputLimit: Int = 600, maximumCharacters: Int = 60_000) -> String {
        var lines: [String] = []
        for item in items {
            switch item {
            case .user(let text): lines.append("USER: \(text)")
            case .assistant(let text): lines.append("ASSISTANT: \(text)")
            case .toolCall(_, let name, let arguments): lines.append("ASSISTANT CALLS \(name) \(arguments)")
            case .toolOutput(_, let output):
                let shown = output.count > perOutputLimit ? String(output.prefix(perOutputLimit)) + " […]" : output
                lines.append("TOOL OUTPUT: \(shown)")
            case .opaque: continue
            }
        }
        return OutputTruncation.headAndTail(lines.joined(separator: "\n"), maxCharacters: maximumCharacters, headShare: 0.4)
    }

    public static func replacing(_ items: [ConversationItem], upTo cut: Int, with summary: String) -> [ConversationItem] {
        [.user(heading + "\n\n" + summary)] + Array(items[cut...])
    }
}
