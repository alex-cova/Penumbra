import Foundation
import Testing
@testable import AgentKit

private func read(_ id: String, path: String) -> [ConversationItem] {
    [.toolCall(id: id, name: "read_file", arguments: #"{"path":"\#(path)","offset":1,"limit":200}"#)]
}

private func big(_ lines: Int = 200) -> String {
    (1...lines).map { "     \($0)\tsome source text on line \($0) of the file" }.joined(separator: "\n")
}

@Suite struct ContextBudgetTests {
    @Test func countsFourBytesToAToken() {
        #expect(ContextBudget.tokens("") == 0)
        #expect(ContextBudget.tokens("abcd") == 1)
        #expect(ContextBudget.tokens("abcde") == 2)
        #expect(ContextBudget.tokens(String(repeating: "é", count: 4)) == 2, "bytes, not characters")
    }

    @Test func itemsAddUpAndToolDefinitionsCount() {
        let items: [ConversationItem] = [.user(String(repeating: "x", count: 400)), .assistant("ok")]
        #expect(ContextBudget.tokens(items) > 100)
        let tool = ToolDefinition(name: "read_file", description: String(repeating: "d", count: 400), parameters: [ToolParameter("path", .string, "p")])
        #expect(ContextBudget.tokens(system: "", tools: [tool]) > 100)
        #expect(ContextBudget.tokens(system: "", tools: []) == 0)
    }
}

@Suite struct ToolOutputStubTests {
    private func conversation(outputs: Int, lines: Int = 200) -> [ConversationItem] {
        var items: [ConversationItem] = [.user("go")]
        for index in 0..<outputs {
            items += read("c\(index)", path: "src/F\(index).java")
            items.append(.toolOutput(callID: "c\(index)", output: big(lines)))
        }
        return items
    }

    private let policy = CompactionPolicy(contextWindow: 8_000, keepRecentToolOutputs: 2)

    @Test func replacesTheOldestOutputsAndKeepsTheNewestWhole() throws {
        let items = conversation(outputs: 6)
        let before = ContextBudget.tokens(items)
        let (result, stubbed) = ToolOutputStubs.apply(to: items, policy: policy, estimatedTokens: before)
        #expect(stubbed > 0 && stubbed <= 4, "never touches the last two")
        let outputs = result.compactMap { item -> String? in if case .toolOutput(_, let text) = item { text } else { nil } }
        #expect(outputs.prefix(stubbed).allSatisfy(ToolOutputStubs.isStub), "oldest first")
        #expect(outputs.suffix(2).allSatisfy { !ToolOutputStubs.isStub($0) })
        #expect(ContextBudget.tokens(result) < before)
        #expect(result.count == items.count, "stubbing changes text, never structure")
    }

    @Test func aStubSaysWhatTheOutputWas() throws {
        let items = conversation(outputs: 6)
        let (result, _) = ToolOutputStubs.apply(to: items, policy: policy, estimatedTokens: ContextBudget.tokens(items))
        guard case .toolOutput(_, let stub) = result[2] else { Issue.record("expected the first output"); return }
        #expect(stub == "[read_file src/F0.java lines 1–200: output elided to save context (200 lines). Call it again if you need it.]")
    }

    @Test func stopsAsSoonAsTheTargetIsReached() {
        let items = conversation(outputs: 6)
        let tokens = ContextBudget.tokens(items)
        // Only a little over target: one stub is enough.
        let nearlyThere = Int(Double(policy.contextWindow) * policy.target) + 50
        let (_, stubbed) = ToolOutputStubs.apply(to: items, policy: policy, estimatedTokens: nearlyThere)
        #expect(stubbed == 1)
        #expect(ToolOutputStubs.apply(to: items, policy: policy, estimatedTokens: 100).stubbed == 0, "under target: nothing to do")
        #expect(tokens > nearlyThere)
    }

    @Test func smallOutputsErrorsAlreadyStubbedAndOutputsWithoutACallAreHandled() {
        var items: [ConversationItem] = [.user("go")]
        items += read("a", path: "A")
        items.append(.toolOutput(callID: "a", output: "short"))
        items.append(.toolOutput(callID: "orphan", output: big()))
        items.append(.toolOutput(callID: "b", output: "[read_file X: \(ToolOutputStubs.marker) (3 lines). Call it again if you need it.]" + String(repeating: " ", count: 700)))
        items += [.toolOutput(callID: "x", output: "keep"), .toolOutput(callID: "y", output: "keep")]
        let (result, stubbed) = ToolOutputStubs.apply(to: items, policy: policy, estimatedTokens: 100_000)
        #expect(stubbed == 1, "only the orphan: the short one is not worth it and the other is already a stub")
        guard case .toolOutput(_, let text) = result[3] else { Issue.record("expected the orphan"); return }
        #expect(text.hasPrefix("[tool output: "))
    }
}

@Suite struct ConversationSummaryTests {
    private func turn(_ n: Int) -> [ConversationItem] {
        [.assistant("thinking \(n)"), .toolCall(id: "c\(n)", name: "grep", arguments: #"{"pattern":"x\#(n)"}"#), .toolOutput(callID: "c\(n)", output: "result \(n)")]
    }

    @Test func theCutFallsWhereAModelTurnBeginsAndKeepsTheNewestTurns() throws {
        let items: [ConversationItem] = [.user("go")] + turn(1) + turn(2) + turn(3) + turn(4)
        let cut = try #require(ConversationSummary.cutIndex(in: items, keepTurns: 2))
        #expect(cut == 7, "turns 3 and 4 are kept")
        if case .toolOutput = items[cut] { Issue.record("a cut must not separate a call from its output") }
        #expect(items[cut] == .assistant("thinking 3"))
    }

    @Test func parallelCallsOfOneTurnStayTogether() throws {
        let items: [ConversationItem] = [
            .user("go"), .toolCall(id: "a", name: "t", arguments: "{}"), .toolCall(id: "b", name: "t", arguments: "{}"),
            .toolOutput(callID: "a", output: "x"), .toolOutput(callID: "b", output: "y"),
        ] + turn(2) + turn(3)
        let cut = try #require(ConversationSummary.cutIndex(in: items, keepTurns: 2))
        #expect(cut == 5)
        // Cutting after the first turn's calls would orphan the outputs; the cut is at a turn start.
        #expect(items[cut] == .assistant("thinking 2"))
    }

    @Test func aSecondUserMessageIsAnAlternativeCutWhenTurnsAreFew() throws {
        let items: [ConversationItem] = [.user("first"), .assistant("a")] + turn(1) + [.user("second"), .assistant("b")]
        #expect(ConversationSummary.cutIndex(in: items, keepTurns: 2) == 5)
    }

    @Test func thereIsNothingToSummarizeInAShortConversation() {
        #expect(ConversationSummary.cutIndex(in: [.user("go")] + turn(1), keepTurns: 2) == nil)
        #expect(ConversationSummary.cutIndex(in: [], keepTurns: 2) == nil)
    }

    @Test func replacingKeepsTheTailAndLabelsTheSummary() {
        let items: [ConversationItem] = [.user("go")] + turn(1) + turn(2)
        let result = ConversationSummary.replacing(items, upTo: 4, with: "We read stuff.")
        #expect(result.count == 1 + 3)
        guard case .user(let text) = result[0] else { Issue.record("expected a user message"); return }
        #expect(text.hasPrefix(ConversationSummary.heading) && text.hasSuffix("We read stuff."))
        #expect(Array(result.dropFirst()) == turn(2))
    }

    @Test func theTranscriptIsPlainTextWithShortenedOutputsAndIsBounded() {
        let items: [ConversationItem] = [.user("fix it"), .toolCall(id: "c", name: "read_file", arguments: "{}"), .toolOutput(callID: "c", output: String(repeating: "z", count: 5_000))]
        let text = ConversationSummary.transcript(of: items, perOutputLimit: 100)
        #expect(text.contains("USER: fix it") && text.contains("ASSISTANT CALLS read_file {}") && text.contains("[…]"))
        #expect(text.count < 400)
        let huge = ConversationSummary.transcript(of: Array(repeating: ConversationItem.user(String(repeating: "q", count: 1_000)), count: 500), maximumCharacters: 5_000)
        #expect(huge.count < 5_200 && huge.contains("characters omitted"))
    }
}
