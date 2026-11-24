import AgentKit
import Foundation
import Testing
@testable import Umbra

@Suite struct IDEAgentTranscriptRowsTests {
    private func call(_ name: String, _ arguments: String = "{}", output: ToolOutput? = ToolOutput("ok")) -> IDEAgentEntry {
        var entry = IDEAgentEntry(kind: .toolCall(name: name), text: arguments)
        entry.output = output
        return entry
    }

    private func text(_ kind: IDEAgentEntry.Kind, _ text: String = "") -> IDEAgentEntry {
        IDEAgentEntry(kind: kind, text: text)
    }

    private func shape(_ rows: [IDEAgentTranscriptRow]) -> [String] {
        rows.map { row in
            switch row {
            case .entry(let entry): "\(entry.kind)"
            case .work(let group): "work(\(group.entries.count))"
            }
        }
    }

    @Test func consecutiveCallsFoldIntoOneGroupBetweenMessages() {
        let entries = [
            text(.user, "fix it"), call("read_file"), call("grep"), call("read_file"),
            text(.assistant, "Done."),
        ]
        let rows = IDEAgentTranscriptRows.make(entries, isRunning: false)
        #expect(shape(rows) == ["user", "work(3)", "assistant"])
    }

    @Test func aSingleCallIsNotFolded() {
        let rows = IDEAgentTranscriptRows.make([text(.user), call("read_file"), text(.assistant)], isRunning: false)
        #expect(shape(rows) == ["user", "toolCall(name: \"read_file\")", "assistant"])
    }

    @Test func whatTheUserHasToSeeBreaksAGroup() {
        var pending = call("run_command", output: nil)
        pending.approval = ApprovalRequest(title: "Run", command: "ls", callID: "c1", toolName: "run_command")
        var question = call("ask_user", output: nil)
        question.question = UserQuestion(callID: "q", question: "Which?")
        let failed = call("edit_file", output: ToolOutput("no match", isError: true))
        let plan = call("exit_plan_mode", output: nil)

        for breaker in [pending, question, failed, plan] {
            let rows = IDEAgentTranscriptRows.make(
                [call("read_file"), call("grep"), breaker, call("glob"), call("list_dir")], isRunning: false)
            #expect(shape(rows) == ["work(2)", "\(breaker.kind)", "work(2)"])
        }
    }

    @Test func anApprovedCallIsFoldedOnceItHasAResult() {
        var approved = call("run_command")
        approved.approval = ApprovalRequest(title: "Run", command: "ls", callID: "c1", toolName: "run_command")
        approved.approvalOutcome = "Approved"
        #expect(shape(IDEAgentTranscriptRows.make([call("read_file"), approved], isRunning: false)) == ["work(2)"])
    }

    @Test func noticesBetweenCallsJoinTheGroupButATrailingOneStaysOut() {
        let entries = [call("read_file"), text(.notice, "Retrying"), call("grep"), text(.notice, "Stopped.")]
        let rows = IDEAgentTranscriptRows.make(entries, isRunning: false)
        #expect(shape(rows) == ["work(3)", "notice"])
    }

    @Test func theGroupKeepsItsIdAsItGrows() {
        let first = call("read_file")
        let two = IDEAgentTranscriptRows.make([first, call("grep")], isRunning: true)
        let three = IDEAgentTranscriptRows.make([first, call("grep"), call("glob")], isRunning: true)
        #expect(two.map(\.id) == [first.id])
        #expect(three.map(\.id) == [first.id])
    }

    @Test func onlyTheGroupTheRunIsStillInIsLive() {
        let entries = [call("read_file"), call("grep"), text(.assistant, "Now editing."), call("edit_file"), call("glob")]
        let running = IDEAgentTranscriptRows.make(entries, isRunning: true)
        let live = running.compactMap { if case .work(let group) = $0 { group.isLive } else { nil } }
        #expect(live == [false, true])

        let finished = IDEAgentTranscriptRows.make(entries, isRunning: false)
        #expect(finished.allSatisfy { if case .work(let group) = $0 { !group.isLive } else { true } })

        let trailingNotice = IDEAgentTranscriptRows.make(entries + [text(.notice, "Retrying")], isRunning: true)
        #expect(trailingNotice.contains { if case .work(let group) = $0 { group.isLive } else { false } })
    }

    @Test func theSummaryCountsStepsDistinctFilesAndCommands() {
        let patch = #"{"patch":"--- a/A.java\n+++ b/A.java\n@@ -1 +1 @@\n-x\n+y\n--- /dev/null\n+++ b/New.java\n"}"#
        let entries = [
            call("edit_file", #"{"path":"A.java"}"#), call("write_file", #"{"path":"B.java"}"#),
            call("apply_patch", patch), call("run_command", #"{"command":"ls"}"#), call("gradle"),
            text(.notice, "Retrying"), call("read_file"),
        ]
        let summary = IDEAgentTranscriptRows.summarize(entries)
        #expect(summary == IDEAgentWorkSummary(steps: 6, filesEdited: 3, commands: 2))
        #expect(summary.text(isLive: false) == "Worked · 6 steps · 3 files edited · 2 commands")
        #expect(IDEAgentWorkSummary(steps: 1).text(isLive: true) == "Working · 1 step")
    }

    @Test func patchedPathsSkipDevNullAndThePrefix() {
        #expect(IDEAgentTranscriptRows.patchedPaths("--- a/x\n+++ b/src/X.java\n+++ /dev/null\n+++ plain.txt") == ["src/X.java", "plain.txt"])
    }

    @Test func rowIDFindsTheGroupAnEntryIsFoldedInto() {
        let first = call("read_file")
        let inner = call("grep")
        let reply = text(.assistant, "ok")
        let rows = IDEAgentTranscriptRows.make([first, inner, reply], isRunning: false)
        #expect(IDEAgentTranscriptRows.rowID(containing: inner.id, in: rows) == first.id)
        #expect(IDEAgentTranscriptRows.rowID(containing: reply.id, in: rows) == reply.id)
        #expect(IDEAgentTranscriptRows.rowID(containing: UUID(), in: rows) == nil)
    }
}

@Suite struct IDEAgentScrollPinTests {
    private func metrics(_ offset: CGFloat, content: CGFloat = 2000, viewport: CGFloat = 500) -> IDEAgentScrollMetrics {
        IDEAgentScrollMetrics(offset: offset, contentHeight: content, viewportHeight: viewport)
    }

    @Test func reachingTheBottomPins() {
        #expect(IDEAgentScrollPin.isPinned(wasPinned: false, from: metrics(800), to: metrics(1480), userIsScrolling: true))
    }

    @Test func scrollingUpUnpins() {
        #expect(!IDEAgentScrollPin.isPinned(wasPinned: true, from: metrics(1500), to: metrics(1200), userIsScrolling: true))
    }

    @Test func aWheelWithoutAPhaseUnpinsWhenOnlyTheOffsetMoved() {
        #expect(!IDEAgentScrollPin.isPinned(wasPinned: true, from: metrics(1500), to: metrics(1300), userIsScrolling: false))
    }

    @Test func newOutputBelowDoesNotUnpin() {
        let grown = metrics(1500, content: 2600)
        #expect(IDEAgentScrollPin.isPinned(wasPinned: true, from: metrics(1500), to: grown, userIsScrolling: false))
    }

    @Test func newOutputDoesNotPinAReaderWhoScrolledUp() {
        let grown = metrics(400, content: 2600)
        #expect(!IDEAgentScrollPin.isPinned(wasPinned: false, from: metrics(400), to: grown, userIsScrolling: false))
    }

    @Test func contentShorterThanTheViewIsAtTheBottom() {
        #expect(metrics(0, content: 200).isAtBottom)
    }
}
