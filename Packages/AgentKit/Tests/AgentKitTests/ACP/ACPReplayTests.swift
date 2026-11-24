import Foundation
import Testing
@testable import AgentKit

/// Record and replay (`docs/harness/agent-harness-11.md`, item 3): a session recorded against the scripted
/// agent, played back by `ACPReplayTransport`, must give the client the same events.
@Suite struct ACPReplayTests {
    /// Events without the parts that differ from run to run.
    private func comparable(_ events: [AgentEvent]) -> [String] {
        events.compactMap { event in
            switch event {
            case .runStarted: "runStarted"
            case .textDelta(let text): "text:\(text)"
            case .approvalRequested(let request): "approval:\(request.title)"
            case .toolCallStarted(_, let name): "tool:\(name)"
            case .toolCallFinished(_, let name, let output): "done:\(name):\(output.isError)"
            case .runEnded(let ending): "ended:\(ending)"
            default: nil
            }
        }
    }

    private func drive(_ session: ACPClientSession, prompt: String) async -> [AgentEvent] {
        var events: [AgentEvent] = []
        for await event in await session.send(prompt) {
            events.append(event)
            if case .approvalRequested(let request) = event {
                await session.resolvePermission(callID: request.callID, optionId: "allow-once")
            }
        }
        return events
    }

    private func record(onPrompt: @escaping @Sendable (FakeACPAgent, String) async -> String) async throws -> ([ACPRecording.Entry], [AgentEvent]) {
        let (clientTransport, agentTransport) = acpPair()
        let agent = await FakeACPAgent.make(transport: agentTransport)
        agent.onPrompt = onPrompt
        let entries = ACPLocked<[ACPRecording.Entry]>([])
        let recording = ACPRecordingTransport(wrapping: clientTransport) { entry in entries.mutate { $0.append(entry) } }
        let session = ACPClientSession(transport: recording, cwd: "/tmp/project")
        let events = await drive(session, prompt: "run it")
        await session.close()
        // The close marker arrives once the forwarding task sees the stream end.
        for _ in 0..<100 where !(entries.get().last?.isClose ?? false) { try await Task.sleep(for: .milliseconds(10)) }
        return (entries.get(), events)
    }

    @Test func aReplayedSessionGivesTheClientTheSameEvents() async throws {
        let (entries, live) = try await record { agent, _ in
            await agent.emitText("Reading. ")
            let outcome = await agent.requestPermission()
            await agent.emitText("chose \(outcome?["outcome"]?["optionId"]?.stringValue ?? "none")")
            return "end_turn"
        }
        #expect(entries.contains { $0.side == .client && $0.frame?["method"]?.stringValue == "session/prompt" })
        #expect(entries.contains { $0.side == .agent && $0.frame?["method"]?.stringValue == "session/request_permission" })

        // Through the file format and back.
        let text = entries.map(\.line).joined(separator: "\n")
        let replay = try ACPReplayTransport(recording: "// recorded from FakeACPAgent\n" + text)
        let session = ACPClientSession(transport: replay, cwd: "/tmp/project")
        let replayed = await drive(session, prompt: "run it")
        #expect(replay.mismatches.isEmpty, "\(replay.mismatches)")
        #expect(comparable(replayed) == comparable(live))
        #expect(comparable(replayed).contains("text:chose allow-once"))
        await session.close()
    }

    @Test func aClientThatSendsSomethingElseIsAMismatch() async throws {
        let (entries, _) = try await record { agent, _ in
            await agent.emitText("hi")
            return "end_turn"
        }
        // The recording now has the client asking for something else where it sends session/new.
        let edited = entries.map { entry -> ACPRecording.Entry in
            guard entry.side == .client, case .object(var object) = entry.frame, object["method"] == "session/new" else { return entry }
            object["method"] = "session/other"
            return ACPRecording.Entry(side: .client, frame: .object(object))
        }
        let replay = ACPReplayTransport(edited)
        let session = ACPClientSession(transport: replay, cwd: "/tmp/project")
        let events = await collectACP(await session.send("run it"))
        #expect(replay.mismatches.first?.got.contains("session/new") == true, "\(replay.mismatches)")
        if case .runEnded(.failed) = events.last {} else { Issue.record("the run fails like a disconnect: \(events)") }
    }

    @Test func aRecordedDisconnectEndsTheRunTheSameWay() async throws {
        let (clientTransport, agentTransport) = acpPair()
        let agent = await FakeACPAgent.make(transport: agentTransport)
        agent.onPrompt = { agent, _ in
            await agent.emitText("partial")
            await agent.crash()
            return "end_turn"
        }
        let entries = ACPLocked<[ACPRecording.Entry]>([])
        let recording = ACPRecordingTransport(wrapping: clientTransport) { entry in entries.mutate { $0.append(entry) } }
        // Kept in a local: a session nothing holds ends its run task before the stream finishes.
        let liveSession = ACPClientSession(transport: recording, cwd: "/tmp/project")
        let live = await collectACP(await liveSession.send("go"))
        #expect(entries.get().last?.isClose == true)

        let replay = ACPReplayTransport(entries.get())
        let replaySession = ACPClientSession(transport: replay, cwd: "/tmp/project")
        let replayed = await collectACP(await replaySession.send("go"))
        #expect(replay.mismatches.isEmpty, "\(replay.mismatches)")
        #expect(comparable(replayed) == comparable(live))
        if case .runEnded(.failed) = replayed.last {} else { Issue.record("expected a failed run: \(replayed)") }
    }

    @Test func scrubbingMapsStringsOnly() {
        let value: JSONValue = .object(["token": "sk-abc", "n": 3, "list": .array(["/Users/me/x", .bool(true)])])
        let scrubbed = ACPRecording.mappingStrings(value) { $0.replacingOccurrences(of: "/Users/me", with: "~") }
        #expect(scrubbed["list"]?.arrayValue?.first?.stringValue == "~/x")
        #expect(scrubbed["token"]?.stringValue == "sk-abc")
        #expect(scrubbed["n"] == .int(3))
    }
}

@Suite struct ACPDroppedSessionTests {
    @Test func aSessionNobodyHoldsStillEndsItsStream() async {
        let (clientTransport, agentTransport) = acpPair()
        _ = await FakeACPAgent.make(transport: agentTransport)
        let events = await collectACP(await ACPClientSession(transport: clientTransport, cwd: "/tmp/project").send("go"))
        #expect(events.last == .runEnded(.stopped))
    }
}
