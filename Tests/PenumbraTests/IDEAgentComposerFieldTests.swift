import AppKit
import SwiftUI
import XCTest

@testable import Umbra

@MainActor
private final class ComposerHarness {
    var text = ""
    var height: CGFloat = 22
    var sends = 0
    var stops = 0
    var accepts = 0
    let state = IDEAgentComposerState()
    var provider: (IDEAgentComposerTrigger) -> [IDEAgentSuggestion] = { _ in [] }
    var history: ((Int) -> String?)?
    var edits = 0
    var window: NSWindow!
    var hosting: NSHostingView<AnyView>!

    init() {
        render()
    }

    func render() {
        let view = IDEAgentComposerField(
            text: Binding(get: { self.text }, set: { self.text = $0 }),
            height: Binding(get: { self.height }, set: { self.height = $0 }),
            placeholder: "Ask", state: state, focusRequest: 0, acceptRequest: accepts,
            suggestions: { [unowned self] in self.provider($0) },
            onSend: { [unowned self] in self.sends += 1 },
            onStop: { [unowned self] in self.stops += 1 },
            onUserEdit: { [unowned self] in self.edits += 1 },
            onHistory: history.map { handler in { handler($0) } })
        if hosting == nil {
            hosting = NSHostingView(rootView: AnyView(view.frame(width: 300, height: height)))
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = hosting
        } else {
            hosting.rootView = AnyView(view.frame(width: 300, height: height))
        }
        hosting.layoutSubtreeIfNeeded()
    }

    var textView: IDEAgentComposerTextView {
        func find(_ view: NSView) -> IDEAgentComposerTextView? {
            if let match = view as? IDEAgentComposerTextView { return match }
            for child in view.subviews { if let match = find(child) { return match } }
            return nil
        }
        return find(hosting)!
    }

    /// Lets SwiftUI and the field's deferred height update run.
    func settle() async {
        try? await Task.sleep(for: .milliseconds(50))
        render()
    }
}

@MainActor
final class IDEAgentComposerFieldTests: XCTestCase {
    func testTypingUpdatesTheBinding() async {
        let harness = ComposerHarness()
        harness.textView.insertText("hello", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(harness.text, "hello")
    }

    func testAnOutsideChangeOfTheDraftReachesTheView() async {
        let harness = ComposerHarness()
        harness.text = "filled from outside"
        harness.render()
        XCTAssertEqual(harness.textView.string, "filled from outside")
        harness.text = ""
        harness.render()
        XCTAssertEqual(harness.textView.string, "", "Send clearing the draft empties the field")
    }

    func testTheFieldGrowsWithItsLinesAndStopsAtEight() async {
        let harness = ComposerHarness()
        let oneLine = harness.height
        harness.textView.insertText("a\nb\nc", replacementRange: NSRange(location: 0, length: 0))
        await harness.settle()
        XCTAssertGreaterThan(harness.height, oneLine, "three lines are taller than one")

        harness.textView.insertText("\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10", replacementRange: NSRange(location: 5, length: 0))
        await harness.settle()
        let capped = harness.height
        harness.textView.insertText("\nmore\nmore", replacementRange: NSRange(location: 0, length: 0))
        await harness.settle()
        XCTAssertEqual(harness.height, capped, accuracy: 0.5, "past eight lines it scrolls instead of growing")

        harness.text = ""
        harness.render()
        await harness.settle()
        XCTAssertEqual(harness.height, oneLine, accuracy: 0.5, "an emptied field shrinks back")
    }

    func testReturnSendsAndShiftReturnInsertsANewline() async throws {
        let harness = ComposerHarness()
        let textView = harness.textView
        textView.insertText("hi", replacementRange: NSRange(location: 0, length: 0))

        textView.keyDown(with: try key(36, window: harness.window))
        XCTAssertEqual(harness.sends, 1)
        XCTAssertEqual(harness.text, "hi", "Return does not add a newline")

        textView.keyDown(with: try key(36, .shift, window: harness.window))
        XCTAssertEqual(harness.sends, 1)
        XCTAssertEqual(harness.text, "hi\n")

        textView.keyDown(with: try key(53, window: harness.window))
        XCTAssertEqual(harness.stops, 1, "Esc with no list stops the run")
    }

    func testASlashRaisesSuggestionsAndTabAcceptsTheHighlightedOne() async throws {
        let harness = ComposerHarness()
        harness.provider = { trigger in
            guard case .slash(let query, _) = trigger else { return [] }
            return ["resume", "rewind", "new"].filter { $0.hasPrefix(query) }.map {
                IDEAgentSuggestion(id: $0, icon: "slash.circle", title: "/\($0)", detail: nil, insertion: "/\($0) ")
            }
        }
        let textView = harness.textView
        textView.insertText("/re", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(harness.state.suggestions.map(\.id), ["resume", "rewind"])

        textView.keyDown(with: try key(125, window: harness.window))
        XCTAssertEqual(harness.state.selected?.id, "rewind", "↓ moves the highlight instead of the caret")

        textView.keyDown(with: try key(48, window: harness.window))
        XCTAssertEqual(harness.text, "/rewind ")
        XCTAssertEqual(harness.sends, 0, "accepting a row does not send")
        XCTAssertFalse(harness.state.isShowingSuggestions, "the list closes once the command has its trailing space")
    }

    func testClickingARowAcceptsItThroughTheField() async {
        let harness = ComposerHarness()
        harness.provider = { trigger in
            guard case .mention = trigger else { return [] }
            return [IDEAgentSuggestion(id: "a", icon: "doc", title: "A.java", detail: nil, insertion: "@A.java ")]
        }
        harness.textView.insertText("see @A", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(harness.state.isShowingSuggestions)

        harness.accepts += 1
        harness.render()
        XCTAssertEqual(harness.text, "see @A.java ")
    }

    func testUpAndDownWalkEarlierPromptsAndComeBackToTheDraft() async throws {
        let harness = ComposerHarness()
        var recall = IDEAgentPromptRecall()
        let prompts = ["first prompt", "second prompt"]
        harness.history = { direction in
            direction < 0 ? recall.previous(current: harness.text, in: prompts) : recall.next(in: prompts)
        }
        harness.render()
        let textView = harness.textView
        textView.insertText("half typed", replacementRange: NSRange(location: 0, length: 0))
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        textView.keyDown(with: try key(126, window: harness.window))
        XCTAssertEqual(harness.text, "second prompt")
        XCTAssertEqual(textView.string, "second prompt")
        textView.keyDown(with: try key(126, window: harness.window))
        XCTAssertEqual(harness.text, "first prompt")
        textView.keyDown(with: try key(125, window: harness.window))
        XCTAssertEqual(harness.text, "second prompt")
        textView.keyDown(with: try key(125, window: harness.window))
        XCTAssertEqual(harness.text, "half typed", "back to what was being typed")
    }

    func testRecalledTextCanBeEditedAndTheEditIsReported() async throws {
        let harness = ComposerHarness()
        harness.history = { _ in "recalled" }
        harness.render()
        let textView = harness.textView
        textView.keyDown(with: try key(126, window: harness.window))
        XCTAssertEqual(harness.text, "recalled")
        XCTAssertEqual(harness.edits, 0, "recalling is not the user typing")
        textView.insertText("!", replacementRange: NSRange(location: 8, length: 0))
        XCTAssertEqual(harness.text, "recalled!")
        XCTAssertEqual(harness.edits, 1)
    }

    func testControlRSearchesEarlierPromptsAndTabPutsTheChosenOneInTheField() async throws {
        let harness = ComposerHarness()
        let prompts = ["fix the parser", "write the docs", "fix the build"]
        harness.provider = { trigger in
            guard case .history(let query, _) = trigger else { return [] }
            return prompts.filter { query.isEmpty || $0.contains(query) }.map {
                IDEAgentSuggestion(id: $0, icon: "clock", title: $0, detail: nil, insertion: $0)
            }
        }
        let textView = harness.textView
        textView.keyDown(with: try key(15, .control, window: harness.window))
        XCTAssertTrue(harness.state.isSearchingHistory)
        XCTAssertEqual(harness.state.suggestions.count, 3, "an empty search lists everything")

        textView.insertText("fix", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(harness.state.suggestions.map(\.id), ["fix the parser", "fix the build"], "what is typed is the search")
        textView.keyDown(with: try key(125, window: harness.window))
        textView.keyDown(with: try key(48, window: harness.window))

        XCTAssertEqual(harness.text, "fix the build", "the whole field became the prompt")
        XCTAssertFalse(harness.state.isSearchingHistory)
        XCTAssertFalse(harness.state.isShowingSuggestions)
        XCTAssertEqual(harness.sends, 0)
    }

    func testEscapeLeavesTheHistorySearchWithoutChangingTheText() async throws {
        let harness = ComposerHarness()
        harness.provider = { trigger in
            guard case .history = trigger else { return [] }
            return [IDEAgentSuggestion(id: "x", icon: "clock", title: "earlier", detail: nil, insertion: "earlier")]
        }
        let textView = harness.textView
        textView.insertText("typed", replacementRange: NSRange(location: 0, length: 0))
        textView.keyDown(with: try key(15, .control, window: harness.window))
        XCTAssertTrue(harness.state.isSearchingHistory)
        textView.keyDown(with: try key(53, window: harness.window))
        XCTAssertFalse(harness.state.isSearchingHistory)
        XCTAssertEqual(harness.text, "typed")
        XCTAssertEqual(harness.stops, 0, "that Esc closed the search, it did not stop a run")
        textView.keyDown(with: try key(15, .control, window: harness.window))
        textView.keyDown(with: try key(15, .control, window: harness.window))
        XCTAssertFalse(harness.state.isSearchingHistory, "Ctrl-R again leaves it too")
    }

    func testMentionsAndCommandsAreColoredButTheTextIsUntouched() async {
        let harness = ComposerHarness()
        let textView = harness.textView
        textView.insertText("/plan check @A.java now", replacementRange: NSRange(location: 0, length: 0))
        let storage = textView.textStorage!
        func color(at index: Int) -> NSColor? { storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor }

        XCTAssertEqual(color(at: 1), IDEAppearance.NSToken.accent, "the command")
        XCTAssertEqual(color(at: 13), IDEAppearance.NSToken.accent, "the mention")
        XCTAssertEqual(color(at: 7), IDEAppearance.NSToken.foreground, "ordinary words")
        XCTAssertEqual(harness.text, "/plan check @A.java now")
    }

    private func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
    }
}
