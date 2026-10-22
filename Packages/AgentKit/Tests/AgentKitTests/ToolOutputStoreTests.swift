import Foundation
import Testing
@testable import AgentKit

final class MemoryOutputStore: ToolOutputStore, @unchecked Sendable {
    private let saved = Locked<[String: String]>([:])
    var accepts = true

    var all: [String: String] { saved.value }
    func save(_ text: String, id: String) -> Bool {
        guard accepts else { return false }
        saved.value[id] = text
        return true
    }
    func load(id: String) -> String? { saved.value[id] }
}

private func context(
    store: (any ToolOutputStore)?, redact: (@Sendable (String) async -> String)? = nil
) throws -> ToolContext {
    ToolContext(
        workspace: try TempProject().workspace, ledger: ReadLedger(), callID: "c",
        outputStore: store, redactOutput: redact)
}

private func numbered(_ count: Int) -> String {
    (1...count).map { "line \($0)" }.joined(separator: "\n")
}

@Suite struct HeadAndTailSavingTests {
    @Test func theFullTextIsSavedAndTheMarkerSaysHowToReadIt() async throws {
        let store = MemoryOutputStore()
        let text = numbered(2_000)
        let shown = await OutputTruncation.headAndTailSaving(text, maxCharacters: 1_000, context: try context(store: store))

        let (id, saved) = try #require(store.all.first)
        #expect(saved == text)
        #expect(shown.hasPrefix("line 1\n") && shown.hasSuffix("line 2000"))
        #expect(shown.contains("characters omitted from the middle. Full output saved: read_tool_output(id: \"\(id)\", offset: "))
        #expect(shown.contains("pattern:"))
        #expect(shown.count < 1_300)
        // The offset names the line the omitted part starts at: the head's last whole line is just before it.
        let offset = try #require(shown.range(of: #"offset: (\d+)"#, options: .regularExpression)
            .flatMap { Int(shown[$0].dropFirst("offset: ".count)) })
        let head = shown.components(separatedBy: "\n[…")[0]
        #expect(offset == head.components(separatedBy: "\n").count + 1)
    }

    @Test func theSavedCopyIsScrubbedWithTheCallsOwnRedactorAndTheShownTextIsLeftToTheShaper() async throws {
        let store = MemoryOutputStore()
        let text = "token=SECRET\n" + numbered(500)
        let redact: @Sendable (String) async -> String = { $0.replacingOccurrences(of: "SECRET", with: "[redacted]") }
        _ = await OutputTruncation.headAndTailSaving(text, maxCharacters: 400, context: try context(store: store, redact: redact))
        let saved = try #require(store.all.values.first)
        #expect(saved.hasPrefix("token=[redacted]\n") && !saved.contains("SECRET"))
    }

    @Test func withoutAStoreOrWhenSavingFailsItIsExactlyHeadAndTail() async throws {
        let text = numbered(2_000)
        let plain = OutputTruncation.headAndTail(text, maxCharacters: 1_000)
        #expect(await OutputTruncation.headAndTailSaving(text, maxCharacters: 1_000, context: try context(store: nil)) == plain)
        let refusing = MemoryOutputStore()
        refusing.accepts = false
        #expect(await OutputTruncation.headAndTailSaving(text, maxCharacters: 1_000, context: try context(store: refusing)) == plain)
    }

    @Test func outputWithinTheLimitIsReturnedAsIsAndNothingIsSaved() async throws {
        let store = MemoryOutputStore()
        let text = numbered(20)
        #expect(await OutputTruncation.headAndTailSaving(text, maxCharacters: 1_000, context: try context(store: store)) == text)
        #expect(store.all.isEmpty)
    }
}

@Suite struct ToolOutputNetTests {
    @Test func moreLinesThanTheNetAllowsAreSavedWholeAndShownFromTheTop() throws {
        let store = MemoryOutputStore()
        let text = numbered(5_000)
        let shown = ToolOutputNet.spill(text, into: store)
        let (id, saved) = try #require(store.all.first)
        #expect(saved == text)
        #expect(shown.hasPrefix("line 1\n"))
        #expect(shown.hasSuffix("[showing lines 1-2500 of 5000; full output saved: read_tool_output(id: \"\(id)\", offset: 2501) pages it, pattern: \"<regex>\" searches it]"))
    }

    @Test func moreBytesThanTheNetAllowsCutsOnALineAndSmallOutputIsUntouched() throws {
        let store = MemoryOutputStore()
        let wide = (1...400).map { _ in String(repeating: "x", count: 500) }.joined(separator: "\n")
        let shown = ToolOutputNet.spill(wide, into: store)
        #expect(shown.utf8.count < ToolOutputNet.maxBytes + 400)
        #expect(shown.contains("[showing lines 1-"))
        #expect(ToolOutputNet.spill(numbered(100), into: store) == numbered(100))
        #expect(store.all.count == 1)
    }

    @Test func aSingleHugeLineShowsItsStartAndAFailedSaveLeavesTheTextAlone() throws {
        let store = MemoryOutputStore()
        let line = String(repeating: "y", count: 300_000)
        let shown = ToolOutputNet.spill(line, into: store)
        #expect(shown.hasPrefix(String(repeating: "y", count: 2_000)) && shown.count < 2_400)
        let refusing = MemoryOutputStore()
        refusing.accepts = false
        #expect(ToolOutputNet.spill(line, into: refusing) == line)
    }
}

/// A tool that returns a lot of text, bounded the way `run_command` is, or not at all.
private struct BigOutputTool: AgentTool {
    let name = "big"
    var risk: ToolRisk = .read
    let text: String
    var bounded = false
    var definition: ToolDefinition { ToolDefinition(name: name, description: "test", parameters: []) }

    func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        bounded ? await OutputTruncation.headAndTailSaving(text, maxCharacters: 2_000, context: context) : text
    }
}

private func run(_ session: AgentSession) async -> [AgentEvent] {
    var events: [AgentEvent] = []
    for await event in await session.send("go") { events.append(event) }
    return events
}

@Suite struct ToolOutputSessionTests {
    private func session(
        _ tool: BigOutputTool, store: (any ToolOutputStore)?, shaper: (@Sendable (ToolOutputShapingInput) async throws -> String)? = nil
    ) throws -> (AgentSession, MockLLMClient) {
        let client = MockLLMClient(turns: [MockTurn.toolCalls((id: "b", name: "big", arguments: "{}")), .text("ok")])
        let project = try TempProject()
        return (AgentSession(
            client: client, tools: [tool], workspace: project.workspace,
            configuration: AgentConfiguration(
                model: "m", approval: .approveAll, shapeToolOutput: shaper, toolOutputStore: store)), client)
    }

    @Test func anOutputNoToolBoundedIsSavedAndTheHistoryKeepsTheTopAndAPointer() async throws {
        let store = MemoryOutputStore()
        let text = numbered(4_000)
        let (session, _) = try session(BigOutputTool(text: text), store: store)
        let events = await run(session)

        let (id, saved) = try #require(store.all.first)
        #expect(saved == text)
        let history = try #require(toolOutputs(await session.items)["b"])
        #expect(history.hasPrefix("line 1\n") && history.contains("read_tool_output(id: \"\(id)\", offset: 2501)"))
        // The live transcript still gets the original.
        let finished = events.compactMap { event -> ToolOutput? in
            if case .toolCallFinished(_, _, let output) = event { output } else { nil }
        }
        #expect(finished.first?.text == text)
    }

    @Test func theSavedCopyIsWhatTheShaperMadeOfIt() async throws {
        let store = MemoryOutputStore()
        let text = "key=SECRET\n" + numbered(4_000)
        let shaper: @Sendable (ToolOutputShapingInput) async throws -> String = { $0.text.replacingOccurrences(of: "SECRET", with: "[redacted]") }
        let (session, _) = try session(BigOutputTool(text: text), store: store, shaper: shaper)
        _ = await run(session)
        #expect(store.all.values.first?.hasPrefix("key=[redacted]\n") == true)
        #expect(!(toolOutputs(await session.items)["b"] ?? "").contains("SECRET"))
    }

    @Test func aToolThatSavesItsOwnOutputIsScrubbedWithItsOwnNameAndRisk() async throws {
        let store = MemoryOutputStore()
        // Like Umbra's scrubber: only command output is scrubbed.
        let shaper: @Sendable (ToolOutputShapingInput) async throws -> String = { input in
            input.risk == .command ? input.text.replacingOccurrences(of: "SECRET", with: "[redacted]") : input.text
        }
        let text = "key=SECRET\n" + numbered(3_000)
        let (session, _) = try session(BigOutputTool(risk: .command, text: text, bounded: true), store: store, shaper: shaper)
        _ = await run(session)
        let history = try #require(toolOutputs(await session.items)["b"])
        #expect(history.contains("Full output saved: read_tool_output(id: "))
        #expect(history.count < 2_600, "the tool's own cap applies, the net does not")
        #expect(store.all.values.first?.hasPrefix("key=[redacted]\n") == true)
    }

    @Test func withoutAStoreNothingChangesAndNoReadToolIsOffered() async throws {
        let (session, client) = try session(BigOutputTool(text: numbered(4_000)), store: nil)
        _ = await run(session)
        #expect(toolOutputs(await session.items)["b"]?.hasSuffix("line 4000") == true)
        #expect(!client.requests[0].tools.contains { $0.name == "read_tool_output" })
    }

    @Test func aStoreBringsTheReadToolEvenInPlanMode() async throws {
        let client = MockLLMClient(turns: [.text("ok")])
        let session = AgentSession(
            client: client, tools: [], workspace: try TempProject().workspace,
            configuration: AgentConfiguration(model: "m", mode: .plan, toolOutputStore: MemoryOutputStore()))
        _ = await run(session)
        #expect(client.requests[0].tools.map(\.name) == ["read_tool_output"])
    }

    @Test func errorsAreNeverSpilled() async throws {
        struct Failing: AgentTool {
            let name = "big"
            var risk: ToolRisk { .read }
            var definition: ToolDefinition { ToolDefinition(name: name, description: "t", parameters: []) }
            func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
                throw ToolError(String(repeating: "z", count: 300_000))
            }
        }
        let store = MemoryOutputStore()
        let client = MockLLMClient(turns: [MockTurn.toolCalls((id: "b", name: "big", arguments: "{}")), .text("ok")])
        let session = AgentSession(
            client: client, tools: [Failing()], workspace: try TempProject().workspace,
            configuration: AgentConfiguration(model: "m", toolOutputStore: store))
        _ = await run(session)
        #expect(store.all.isEmpty)
    }
}

@Suite struct ReadToolOutputTests {
    private func call(_ json: String, store: MemoryOutputStore) async throws -> String {
        let tool = ReadToolOutputTool(store: store)
        let result = await tool.execute(argumentsJSON: json, context: try context(store: store))
        return result.text
    }

    private func stored(_ text: String) -> (MemoryOutputStore, String) {
        let store = MemoryOutputStore()
        _ = store.save(text, id: "out_abc")
        return (store, "out_abc")
    }

    @Test func pagesByLineWithAFooterThatSaysWhereToContinue() async throws {
        let (store, id) = stored(numbered(1_000))
        let first = try await call(#"{"id":"\#(id)","limit":3}"#, store: store)
        #expect(first.hasPrefix("[tool output out_abc: lines 1–3 of 1000]\n"))
        #expect(first.contains("     1\tline 1\n") && first.hasSuffix("[997 more lines. Use offset=4 to continue.]"))
        let later = try await call(#"{"id":"\#(id)","offset":998}"#, store: store)
        #expect(later.contains("   998\tline 998") && later.contains("  1000\tline 1000") && !later.contains("more lines"))
    }

    @Test func aPatternListsOnlyMatchingLinesWithTheirNumbers() async throws {
        let (store, id) = stored(numbered(1_000))
        let found = try await call(#"{"id":"\#(id)","pattern":"^line 9[0-9]$"}"#, store: store)
        #expect(found.hasPrefix("[tool output out_abc: 10 matching lines of 1000]\n"))
        #expect(found.contains("    90\tline 90") && found.contains("    99\tline 99") && !found.contains("line 100"))
        #expect(try await call(#"{"id":"\#(id)","pattern":"nothing like this"}"#, store: store).contains("no line matches"))
        #expect(try await call(#"{"id":"\#(id)","pattern":"("}"#, store: store).contains("not a valid regular expression"))
    }

    @Test func manyMatchesAreCappedWithAHint() async throws {
        let (store, id) = stored(numbered(1_000))
        let found = try await call(#"{"id":"\#(id)","pattern":"line"}"#, store: store)
        #expect(found.contains("1000 matching lines of 1000") && found.contains("[800 more matches. Use a narrower pattern.]"))
    }

    @Test func anUnknownOrPathLikeIdIsAClearError() async throws {
        let (store, _) = stored("x")
        #expect(try await call(#"{"id":"out_missing"}"#, store: store).contains("No saved output with id \"out_missing\""))
        let escaped = try await call(#"{"id":"../../etc/passwd"}"#, store: store)
        #expect(escaped.contains("No saved output"))
        #expect(!ToolOutputID.isValid("../x") && !ToolOutputID.isValid("a/b") && !ToolOutputID.isValid("") && ToolOutputID.isValid("out_ab-12"))
        let (store2, id) = stored(numbered(5))
        #expect(try await call(#"{"id":"\#(id)","offset":99}"#, store: store2).contains("past the end"))
    }

    @Test func aLongLineIsClippedAndTheIdsAreFreshEachTime() async throws {
        let (store, id) = stored(String(repeating: "w", count: 5_000))
        let out = try await call(#"{"id":"\#(id)"}"#, store: store)
        #expect(out.contains("…[line truncated]") && out.count < 700)
        #expect(ToolOutputID.make() != ToolOutputID.make() && ToolOutputID.isValid(ToolOutputID.make()))
    }
}

@Suite struct StubsKeepSavedOutputTests {
    @Test func aCompactionStubStillPointsAtTheSavedOutput() {
        let output = "head\n[… 90000 characters omitted from the middle. Full output saved: read_tool_output(id: \"out_9f3a\", offset: 40) pages it, pattern: \"<regex>\" searches it …]\ntail"
        let items: [ConversationItem] = [
            .user("go"), .toolCall(id: "c", name: "run_command", arguments: #"{"command":"swift test"}"#),
            .toolOutput(callID: "c", output: output),
        ]
        let stub = ToolOutputStubs.describe(callID: "c", output: output, in: items, before: 2)
        #expect(stub.contains("read_tool_output(id: \"out_9f3a\")"))
        #expect(ToolOutputStubs.isStub(stub))
        // An ordinary output keeps the old wording.
        #expect(ToolOutputStubs.describe(callID: "c", output: "plain", in: items, before: 2).hasSuffix("Call it again if you need it.]"))
    }
}
