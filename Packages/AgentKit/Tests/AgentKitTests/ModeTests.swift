import Foundation
import Testing
@testable import AgentKit

private func roundTrip(old: String?, new: String) throws -> String {
    let diff = UnifiedDiff.make(path: "F.txt", old: old, new: new)
    let files = try PatchParser.parse(diff)
    return try PatchPlanner.plan(files[0], text: old).expected
}

@Suite struct UnifiedDiffTests {
    @Test func aSmallChangeInTheMiddleShowsContextAndApplies() throws {
        let old = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let new = old.replacingOccurrences(of: "line 10\n", with: "line ten\nextra\n")
        let diff = UnifiedDiff.make(path: "F.txt", old: old, new: new)
        #expect(diff == """
        --- a/F.txt
        +++ b/F.txt
        @@ -7,7 +7,8 @@
         line 7
         line 8
         line 9
        -line 10
        +line ten
        +extra
         line 11
         line 12
         line 13

        """)
        #expect(try roundTrip(old: old, new: new) == new)
    }

    @Test func distantChangesAreSeparateHunksAndNearbyOnesShareOne() throws {
        let old = (1...40).map { "l\($0)" }.joined(separator: "\n") + "\n"
        let far = old.replacingOccurrences(of: "l3\n", with: "THREE\n").replacingOccurrences(of: "l38\n", with: "THIRTY-EIGHT\n")
        #expect(UnifiedDiff.make(path: "F", old: old, new: far).components(separatedBy: "@@ -").count - 1 == 2, "two hunks")
        #expect(try roundTrip(old: old, new: far) == far)
        let near = old.replacingOccurrences(of: "l3\n", with: "THREE\n").replacingOccurrences(of: "l5\n", with: "FIVE\n")
        #expect(UnifiedDiff.make(path: "F", old: old, new: near).components(separatedBy: "@@ -").count - 1 == 1)
        #expect(try roundTrip(old: old, new: near) == near)
    }

    @Test func newFilesDeletionsAndWholeRewritesRoundTrip() throws {
        let created = UnifiedDiff.make(path: "N.txt", old: nil, new: "a\nb\n")
        #expect(created.hasPrefix("--- /dev/null\n+++ b/N.txt\n@@ -0,0 +1,2 @@\n+a\n+b\n"))
        #expect(try roundTrip(old: nil, new: "a\nb\n") == "a\nb\n")
        #expect(try roundTrip(old: "x\ny\nz\n", new: "completely\ndifferent\n") == "completely\ndifferent\n")
        #expect(try roundTrip(old: "a\nb\nc\n", new: "a\nc\n") == "a\nc\n")
        #expect(UnifiedDiff.make(path: "S", old: "same\n", new: "same\n") == "--- a/S\n+++ b/S\n", "no change, no hunks")
    }

    @Test func reorderedAndRepeatedLinesStillRoundTrip() throws {
        let old = "a\nb\na\nb\nc\na\n"
        for new in ["b\na\nb\nc\na\n", "a\nb\nc\nb\na\na\n", "c\nb\na\n", "a\na\na\nb\nb\nc\n", "a\nb\na\nb\nc\na\nd\n"] {
            #expect(try roundTrip(old: old, new: new) == new, "\(new.debugDescription)")
        }
    }

    @Test func blankLinesAndMissingFinalNewlinesSurvive() throws {
        let old = "a\n\nb\n\n\nc\n"
        #expect(try roundTrip(old: old, new: "a\n\nB\n\n\nc\n") == "a\n\nB\n\n\nc\n")
        #expect(try roundTrip(old: old, new: "a\n\n\nc\n") == "a\n\n\nc\n")
    }

    @Test func aHugeUnalignedMiddleFallsBackToAReplacedBlockInsteadOfHanging() {
        let old = (0..<3_000).map { "old \($0)" }.joined(separator: "\n") + "\n"
        let new = (0..<3_000).map { "new \($0)" }.joined(separator: "\n") + "\n"
        let diff = UnifiedDiff.make(path: "Big", old: old, new: new)
        #expect(diff.contains("-old 0") && diff.contains("+new 2999"))
    }

    @Test func manyRandomEditsRoundTrip() throws {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<60 {
            let old = (0..<Int.random(in: 0...30, using: &generator)).map { _ in String(Int.random(in: 0...6, using: &generator)) }
            var new = old
            for _ in 0..<Int.random(in: 0...5, using: &generator) {
                switch Int.random(in: 0...2, using: &generator) {
                case 0 where !new.isEmpty: new.remove(at: Int.random(in: 0..<new.count, using: &generator))
                case 1: new.insert(String(Int.random(in: 0...6, using: &generator)), at: Int.random(in: 0...new.count, using: &generator))
                default: if !new.isEmpty { new[Int.random(in: 0..<new.count, using: &generator)] = "x" }
                }
            }
            let oldText = old.isEmpty ? "" : old.joined(separator: "\n") + "\n"
            let newText = new.isEmpty ? "" : new.joined(separator: "\n") + "\n"
            guard oldText != newText, !oldText.isEmpty, !newText.isEmpty else { continue }
            #expect(try roundTrip(old: oldText, new: newText) == newText, "\(oldText.debugDescription) -> \(newText.debugDescription)")
        }
    }
}

private struct Fixture {
    let project: TempProject

    init(files: [String: String] = ["A.txt": "one\ntwo\nthree\n"]) throws { project = try TempProject(files: files) }

    func session(_ client: MockLLMClient, mode: PermissionMode) -> AgentSession {
        AgentSession(
            client: client, tools: ReadOnlyTools.all() + EditingTools.all(), workspace: project.workspace,
            configuration: AgentConfiguration(model: "m", mode: mode))
    }

    func disk(_ path: String) -> String? { try? String(contentsOf: project.root.appendingPathComponent(path), encoding: .utf8) }
}

private func read(_ id: String = "r") -> MockTurn { .toolCalls((id: id, name: "read_file", arguments: #"{"path":"A.txt"}"#)) }
private func edit(_ id: String = "e", _ old: String = "two", _ new: String = "2") -> MockTurn {
    .toolCalls((id: id, name: "edit_file", arguments: #"{"path":"A.txt","old_string":"\#(old)","new_string":"\#(new)"}"#))
}

private func drive(_ agent: AgentSession, decide: ((ApprovalRequest) -> ApprovalDecision?)?) async -> [AgentEvent] {
    var events: [AgentEvent] = []
    for await event in await agent.send("go") {
        events.append(event)
        if case .approvalRequested(let request) = event, let decision = decide?(request) {
            await agent.resolveApproval(callID: request.callID, decision: decision)
        }
    }
    return events
}

@Suite struct PermissionModeTests {
    @Test func planOffersOnlyTheToolsThatLookAndRefusesTheOthers() async throws {
        let f = try Fixture()
        let client = MockLLMClient(turns: [read(), edit(), .toolCalls((id: "x", name: "run_command", arguments: #"{"command":"ls"}"#)), .text("Here is the plan.")])
        let agent = f.session(client, mode: .plan)
        let events = await drive(agent, decide: nil)

        #expect(events.last == .runEnded(.completed))
        #expect(Set(client.requests[0].tools.map(\.name)) == Set(ReadOnlyTools.all().map(\.name)), "no edit or command tool is even described")
        let outputs = toolOutputs(await agent.items)
        #expect(outputs["r"]?.contains("lines 1–3") == true, "reading still works")
        #expect(outputs["e"]?.contains("plan mode") == true && outputs["x"]?.contains("Unknown tool") == true, "a tool this session never had stays unknown")
        #expect(f.disk("A.txt") == "one\ntwo\nthree\n", "nothing was changed")
        #expect(!events.contains { if case .approvalRequested = $0 { true } else { false } })
        expectEveryCallAnswered(await agent.items)
    }

    @Test func manualAsksWithTheDiffAndAppliesOnApproval() async throws {
        let f = try Fixture()
        let client = MockLLMClient(turns: [read(), edit(), .text("done")])
        let agent = f.session(client, mode: .manual)
        var seen: ApprovalRequest?
        let events = await drive(agent) { request in seen = request; return .approve }

        let request = try #require(seen)
        #expect(request.title == "Apply edit" && request.toolName == "edit_file")
        #expect(request.command == "Edit A.txt (1 occurrence)")
        let diff = try #require(request.diff)
        #expect(diff.contains("--- a/A.txt") && diff.contains("-two") && diff.contains("+2"))
        #expect(f.disk("A.txt") == "one\n2\nthree\n")
        #expect(events.last == .runEnded(.completed))
        #expect(client.requests[0].tools.count == ReadOnlyTools.all().count + EditingTools.all().count, "the model still has every tool")
    }

    @Test func rejectingAnEditChangesNothingAndTellsTheModel() async throws {
        let f = try Fixture()
        let client = MockLLMClient(turns: [read(), edit(), .text("ok, what would you prefer?")])
        let agent = f.session(client, mode: .manual)
        _ = await drive(agent) { _ in .deny(note: "keep it as is") }

        #expect(f.disk("A.txt") == "one\ntwo\nthree\n")
        let output = try #require(toolOutputs(await agent.items)["e"])
        #expect(output.contains("The user rejected this edit; nothing was changed.") && output.contains("keep it as is"))
    }

    @Test func aRejectedEditLeavesNoCheckpointAndAnApprovedOneDoes() async throws {
        let f = try Fixture()
        let rejecting = f.session(MockLLMClient(turns: [read(), edit(), .text("done")]), mode: .manual)
        _ = await drive(rejecting) { _ in .deny(note: nil) }
        #expect(await rejecting.checkpoints.runs.isEmpty)

        let approving = f.session(MockLLMClient(turns: [read(), edit(), .text("done")]), mode: .manual)
        _ = await drive(approving) { _ in .approve }
        #expect(await approving.checkpoints.runs.count == 1)
    }

    @Test func writeFileAndApplyPatchAskToo() async throws {
        let f = try Fixture()
        let client = MockLLMClient(turns: [
            read(),
            .toolCalls((id: "w", name: "write_file", arguments: #"{"path":"New.txt","content":"hello\n"}"#)),
            .toolCalls((id: "p", name: "apply_patch", arguments: #"{"patch":"--- a/A.txt\n+++ b/A.txt\n@@ -1,3 +1,3 @@\n one\n-two\n+TWO\n three\n"}"#)),
            .text("done"),
        ])
        let agent = f.session(client, mode: .manual)
        var titles: [String] = []
        _ = await drive(agent) { request in titles.append(request.command); return .approve }
        #expect(titles == ["Create New.txt", "Patch A.txt"])
        #expect(f.disk("New.txt") == "hello\n" && f.disk("A.txt") == "one\nTWO\nthree\n")
    }

    @Test func aCallThatCannotBePreviewedIsNotAskedAboutAndFailsOnItsOwn() async throws {
        let f = try Fixture()
        // Never read, so the edit would be refused: asking the user to approve it would be a pointless question.
        let client = MockLLMClient(turns: [edit(), .text("ok")])
        let agent = f.session(client, mode: .manual)
        let events = await drive(agent, decide: nil)
        #expect(!events.contains { if case .approvalRequested = $0 { true } else { false } })
        #expect(toolOutputs(await agent.items)["e"] == "Error: Read A.txt with read_file before changing it.")
    }

    @Test func theDefaultModeAppliesEditsWithoutAsking() async throws {
        let f = try Fixture()
        let client = MockLLMClient(turns: [read(), edit(), .text("done")])
        let events = await drive(f.session(client, mode: .acceptEdits), decide: nil)
        #expect(!events.contains { if case .approvalRequested = $0 { true } else { false } })
        #expect(f.disk("A.txt") == "one\n2\nthree\n")
    }

    @Test func commandsStillAskInEveryMode() async throws {
        #expect(PermissionMode.allCases.allSatisfy { $0.offers(.read) })
        #expect(PermissionMode.plan.offers(.command) == false && PermissionMode.manual.offers(.command))
    }

    @Test func thePlanPromptTellsTheModelItCannotChangeAnything() {
        #expect(SystemPrompt.make(projectRoot: "/p", mode: .plan).contains("Plan mode"))
        #expect(SystemPrompt.make(projectRoot: "/p", mode: .manual).contains("shown to the user as a diff"))
        #expect(!SystemPrompt.make(projectRoot: "/p").contains("Plan mode"))
        let withNotes = SystemPrompt.make(projectRoot: "/p", notes: "Use tabs.")
        #expect(withNotes.contains("Project instructions") && withNotes.hasSuffix("Use tabs."))
    }
}
