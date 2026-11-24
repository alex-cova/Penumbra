import AgentKit
import XCTest
@testable import Umbra

final class IDEACPHandoffTests: XCTestCase {
    func testMessagesAreKeptAndToolRunsBecomeOneLine() {
        var failed = IDEAgentEntry(kind: .toolCall(name: "run_command"), text: "{}")
        failed.output = .error("exit 1")
        var read = IDEAgentEntry(kind: .toolCall(name: "read_file"), text: "{}")
        read.output = ToolOutput("ok")
        let entries = [
            IDEAgentEntry(kind: .user, text: "Fix the build."),
            read, read,
            failed,
            IDEAgentEntry(kind: .notice, text: "Stopped."),
            IDEAgentEntry(kind: .assistant, text: "The test fails on line 3."),
            IDEAgentEntry(kind: .error, text: "The ACP agent disconnected."),
            IDEAgentEntry(kind: .changes, text: ""),
        ]
        XCTAssertEqual(IDEACPHandoff.turns(from: entries), [
            HandoffTurn(role: .user, text: "Fix the build."),
            HandoffTurn(role: .activity, text: "Used tools: read_file ×2, run_command (failed)"),
            HandoffTurn(role: .assistant, text: "The test fails on line 3."),
        ])
    }

    func testThePartialNoticeAppearsOnlyWhenSomethingWasLeftOut() throws {
        let short = try XCTUnwrap(ConversationHandoff.make(turns: [HandoffTurn(role: .user, text: "hi")]))
        XCTAssertNil(IDEACPHandoff.partialNotice(short))
        let turns = (0..<200).map { HandoffTurn(role: $0.isMultiple(of: 2) ? .user : .assistant, text: String(repeating: "w", count: 500)) }
        let long = try XCTUnwrap(ConversationHandoff.make(turns: turns))
        let notice = try XCTUnwrap(IDEACPHandoff.partialNotice(long))
        XCTAssertTrue(notice.contains("of 200 earlier messages"), notice)
    }

    func testTheSwitchNoticeSaysWhetherTheConversationGoesAlong() {
        XCTAssertEqual(
            IDEACPHandoff.switchNotice(next: "Codex", previous: "Claude Code", title: nil, carries: false),
            "This chat uses Codex. Claude Code stays in its own chat.")
        let carried = IDEACPHandoff.switchNotice(next: "Codex", previous: "Claude Code", title: "Fix the build", carries: true)
        XCTAssertTrue(carried.contains("continues “Fix the build”"), carried)
        XCTAssertTrue(carried.contains("Your first message brings that conversation with it."), carried)
    }
}
