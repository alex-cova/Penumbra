import AgentKit
import Foundation
import Testing
@testable import Umbra

@Suite struct IDEAgentTranscriptFindTests {
    private func entry(_ kind: IDEAgentEntry.Kind, _ text: String = "") -> IDEAgentEntry {
        IDEAgentEntry(kind: kind, text: text)
    }

    @Test func findsMessagesIgnoringCaseAndAccentsInTranscriptOrder() {
        let user = entry(.user, "Fix the Café menu")
        let reply = entry(.assistant, "The cafe menu is in Menu.java.")
        let other = entry(.assistant, "Nothing here")
        #expect(IDEAgentTranscriptFind.matches("CAFE", in: [user, reply, other]) == [user.id, reply.id])
        #expect(IDEAgentTranscriptFind.matches("  ", in: [user]).isEmpty)
    }

    @Test func aToolCallIsFoundByItsTitleAndOutputButNotItsRawArguments() {
        var read = entry(.toolCall(name: "read_file"), #"{"path":"src/Menu.java"}"#)
        read.output = ToolOutput("class Menu { int price; }")
        var command = entry(.toolCall(name: "run_command"), #"{"command":"gradle test"}"#)
        command.liveOutput = "BUILD SUCCESSFUL"
        let entries = [read, command]
        #expect(IDEAgentTranscriptFind.matches("Menu.java", in: entries) == [read.id])
        #expect(IDEAgentTranscriptFind.matches("price", in: entries) == [read.id])
        #expect(IDEAgentTranscriptFind.matches("successful", in: entries) == [command.id])
        #expect(IDEAgentTranscriptFind.matches("\"path\"", in: entries).isEmpty)
    }

    @Test func aChangesCardIsFoundByItsFiles() {
        var card = entry(.changes)
        card.fileChanges = [IDEAgentFileChange(path: "src/Menu.java", original: "")]
        #expect(IDEAgentTranscriptFind.matches("menu.java", in: [card]) == [card.id])
    }

    @Test func steppingWrapsAndStartsAtEitherEnd() {
        let ids = [UUID(), UUID(), UUID()]
        #expect(IDEAgentTranscriptFind.next(after: nil, by: 1, in: ids) == ids[0])
        #expect(IDEAgentTranscriptFind.next(after: nil, by: -1, in: ids) == ids[2])
        #expect(IDEAgentTranscriptFind.next(after: ids[2], by: 1, in: ids) == ids[0])
        #expect(IDEAgentTranscriptFind.next(after: ids[0], by: -1, in: ids) == ids[2])
        #expect(IDEAgentTranscriptFind.next(after: nil, by: 1, in: []) == nil)
    }

    @Test func thePositionSaysWhereYouAre() {
        let ids = [UUID(), UUID(), UUID()]
        #expect(IDEAgentTranscriptFind.position(of: ids[1], in: ids) == "2 of 3")
        #expect(IDEAgentTranscriptFind.position(of: nil, in: ids) == "3 found")
        #expect(IDEAgentTranscriptFind.position(of: nil, in: []) == "No results")
    }
}

@Suite struct IDEAgentMinimapItemsTests {
    @Test func oneTickPerUserMessageWithItsLastReplyAndFlags() {
        var changes = IDEAgentEntry(kind: .changes, text: "")
        changes.fileChanges = [IDEAgentFileChange(path: "A.txt", original: "a")]
        var waiting = IDEAgentEntry(kind: .toolCall(name: "ask_user"), text: "{}")
        waiting.question = UserQuestion(callID: "q", question: "Which?")
        let entries = [
            IDEAgentEntry(kind: .notice, text: "before any message"),
            IDEAgentEntry(kind: .user, text: "First\nsecond line"),
            IDEAgentEntry(kind: .assistant, text: "Working on it."),
            IDEAgentEntry(kind: .assistant, text: "Done.\nDetails"),
            changes,
            IDEAgentEntry(kind: .user, text: "Next"),
            waiting,
        ]
        let items = IDEAgentMinimapItems.make(entries)
        #expect(items.map(\.prompt) == ["First", "Next"])
        #expect(items.map(\.reply) == ["Done.", nil])
        #expect(items.map(\.changedFiles) == [true, false])
        #expect(items.map(\.isWaiting) == [false, true])
        #expect(items[0].position == 1.0 / 7.0)
        #expect(items[0].id == entries[1].id)
    }

    @Test func aRevertedRunDoesNotMarkTheTurn() {
        var changes = IDEAgentEntry(kind: .changes, text: "")
        changes.isReverted = true
        let items = IDEAgentMinimapItems.make([IDEAgentEntry(kind: .user, text: "Go"), changes])
        #expect(items.first?.changedFiles == false)
    }

    @Test func aLongPromptIsCut() {
        let items = IDEAgentMinimapItems.make([IDEAgentEntry(kind: .user, text: String(repeating: "x", count: 300))])
        #expect(items.first?.prompt.count == 120)
        #expect(items.first?.prompt.hasSuffix("…") == true)
    }
}
