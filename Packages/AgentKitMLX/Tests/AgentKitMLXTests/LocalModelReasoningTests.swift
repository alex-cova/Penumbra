import Foundation
import Testing
@testable import AgentKitMLX

struct LocalModelReasoningTests {
    typealias Delta = LocalModelReasoningParser.Delta

    /// Feeds `chunks` in order, then flushes, and merges adjacent same-kind text so assertions
    /// don't depend on where the chunk boundaries fell.
    private func run(_ chunks: [String], allowsImplicitOpen: Bool = true) -> [Delta] {
        var parser = LocalModelReasoningParser(allowsImplicitOpen: allowsImplicitOpen)
        var raw = chunks.flatMap { parser.consume($0) }
        raw += parser.finish()

        var merged: [Delta] = []
        for delta in raw {
            switch (merged.last, delta) {
            case (.reasoning(let a)?, .reasoning(let b)): merged[merged.count - 1] = .reasoning(a + b)
            case (.answer(let a)?, .answer(let b)): merged[merged.count - 1] = .answer(a + b)
            default: merged.append(delta)
            }
        }
        return merged
    }

    @Test func splitsAThinkBlockFromTheAnswer() {
        #expect(run(["<think>a</think>b"]) == [.reasoning("a"), .reasoningEnded, .answer("b")])
    }

    @Test func supportsTheReasoningTagToo() {
        #expect(run(["<reasoning>a</reasoning>b"]) == [.reasoning("a"), .reasoningEnded, .answer("b")])
    }

    @Test func aTagSplitAcrossChunksStillParses() {
        #expect(run(["<thi", "nk>x</thi", "nk>y"]) == [.reasoning("x"), .reasoningEnded, .answer("y")])
    }

    @Test func aTagSplitOneCharacterAtATimeStillParses() {
        let chunks = "<think>plan</think>done".map(String.init)
        #expect(run(chunks) == [.reasoning("plan"), .reasoningEnded, .answer("done")])
    }

    @Test func textWithoutTagsIsAllAnswer() {
        #expect(run(["Hello, ", "world."]) == [.answer("Hello, world.")])
    }

    @Test func padNewlinesAroundTagsAreDropped() {
        #expect(run(["<think>\nplan\n</think>\n\nanswer"]) == [.reasoning("plan\n"), .reasoningEnded, .answer("answer")])
    }

    @Test func aClosingTagWithNoOpenerReclassifiesEarlierAnswerText() {
        #expect(run(["abc</think>def"]) == [
            .answer("abc"), .reclassifyAnswerAsReasoning, .reasoningEnded, .answer("def"),
        ])
    }

    @Test func withoutImplicitOpenAStrayClosingTagIsSwallowedAndTheTextKept() {
        #expect(run(["abc</think>def"], allowsImplicitOpen: false) == [.answer("abcdef")])
    }

    @Test func onlyTheFirstStrayClosingTagReclassifies() {
        let deltas = run(["abc</think>def</think>ghi"])
        #expect(deltas.filter { $0 == .reclassifyAnswerAsReasoning }.count == 1)
        #expect(deltas.last == .answer("defghi"))
    }

    @Test func aStrayClosingTagAfterARealBlockDoesNotReclassify() {
        let deltas = run(["<think>a</think>b</think>c"])
        #expect(!deltas.contains(.reclassifyAnswerAsReasoning))
        #expect(deltas.last == .answer("bc"))
    }

    @Test func aDanglingAngleBracketIsFlushedAsProse() {
        #expect(run(["if 2 < "]) == [.answer("if 2 < ")])
        #expect(run(["a <", "b"]) == [.answer("a <b")])
    }

    @Test func aHalfTagAtTheEndOfTheStreamIsFlushedAsProse() {
        #expect(run(["ok <thi"]) == [.answer("ok <thi")])
    }

    @Test func anUnclosedBlockStaysReasoningAndEnds() {
        #expect(run(["<think>still going"]) == [.reasoning("still going"), .reasoningEnded])
    }

    @Test func aRepeatedOpenerInsideABlockIsSwallowed() {
        #expect(run(["<think><think>a</think>b"]) == [.reasoning("a"), .reasoningEnded, .answer("b")])
    }

    @Test func aMismatchedClosingTagInsideABlockIsPlainReasoning() {
        #expect(run(["<think>a</reasoning>b</think>c"]) == [
            .reasoning("a</reasoning>b"), .reasoningEnded, .answer("c"),
        ])
    }

    @Test func aSecondBlockAfterTheAnswerStartsIsReasoningAgain() {
        #expect(run(["<think>a</think>b<think>c</think>d"]) == [
            .reasoning("a"), .reasoningEnded, .answer("b"), .reasoning("c"), .reasoningEnded, .answer("d"),
        ])
    }

    @Test func nothingIsEmittedTwiceOrLost() {
        let source = "<think>weigh 3 < 4 and 5 > 2</think>x < y, so <b>bold</b> wins"
        let deltas = run(source.map(String.init))
        let reasoning = deltas.compactMap { if case .reasoning(let t) = $0 { t } else { nil } }.joined()
        let answer = deltas.compactMap { if case .answer(let t) = $0 { t } else { nil } }.joined()
        #expect(reasoning == "weigh 3 < 4 and 5 > 2")
        #expect(answer == "x < y, so <b>bold</b> wins")
    }
}
