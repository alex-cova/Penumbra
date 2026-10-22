import Testing
@testable import AgentKitMLX

@Suite struct StopMarkerFilterTests {
    private func run(_ chunks: [String]) -> (text: String, stopped: Bool) {
        var filter = StopMarkerFilter()
        var out = ""
        for chunk in chunks { out += filter.consume(chunk) }
        out += filter.finish()
        return (out, filter.stopped)
    }

    @Test func dropsEverythingFromTheMarkerOn() {
        // What Umbra's export showed: the marker first, then an invented user turn.
        let result = run(["<|endoftext|>Human: improve current file, must be a form"])
        #expect(result.text.isEmpty)
        #expect(result.stopped)
    }

    @Test func keepsTheAnswerBeforeTheMarker() {
        let result = run(["Done.", "<|im_end|>", "<|im_start|>user\nmore"])
        #expect(result.text == "Done.")
        #expect(result.stopped)
    }

    @Test func findsAMarkerSplitAcrossChunks() {
        let result = run(["All set.<|end", "of", "text|>Human: again"])
        #expect(result.text == "All set.")
        #expect(result.stopped)
    }

    @Test func passesTextThatOnlyLooksLikeAMarker() {
        let result = run(["a <| b ", "and <|not a marker|> c <"])
        #expect(result.text == "a <| b and <|not a marker|> c <")
        #expect(!result.stopped)
    }

    @Test func stopsAtAnInventedUserTurn() {
        // What Umbra's export showed from a 1.5B model: no special token, just role headers.
        let result = run(["hiogenous\nUser: hiogenous\nAssistant: Hi"])
        #expect(result.text == "hiogenous")
        #expect(result.stopped)
    }

    @Test func stopsAtAHeaderAtTheStartOfAChunk() {
        let result = run(["Hello.\n", "User: more"])
        #expect(result.text == "Hello.")
        #expect(result.stopped)
    }

    @Test func onlyAnInventedTurnCountsAsDegenerate() {
        var header = StopMarkerFilter()
        _ = header.consume("Hello.\nUser: and then?")
        #expect(header.stopped && header.stoppedAtInventedTurn)
        var marker = StopMarkerFilter()
        _ = marker.consume("Hello.<|im_end|>more")
        #expect(marker.stopped && !marker.stoppedAtInventedTurn, "the model's own end token is a normal finish")
    }

    @Test func stopsAtAHeaderOpeningTheTurn() {
        let result = run(["Human: hi"])
        #expect(result.text.isEmpty)
        #expect(result.stopped)
    }

    @Test func findsAHeaderSplitAcrossChunks() {
        let twoChunks = run(["Done.\nUs", "er: again"])
        #expect(twoChunks.text == "Done.")
        #expect(twoChunks.stopped)

        let manyChunks = run(["Done.\n", "U", "s", "er:"])
        #expect(manyChunks.text == "Done.")
        #expect(manyChunks.stopped)

        let opening = run(["Hu", "man:", " hi"])
        #expect(opening.text.isEmpty)
        #expect(opening.stopped)
    }

    @Test func stopsAtAHeaderAfterACRLFLineBreak() {
        let whole = run(["Done.\r\nUser: again"])
        #expect(whole.text == "Done.")
        #expect(whole.stopped)

        let split = run(["Done.\r", "\nUser:", " again"])
        #expect(split.text == "Done.")
        #expect(split.stopped)
    }

    @Test func passesUserMidLineAndLookalikes() {
        let text = "Ask the User: what now?\nUsername: alex\nuser: x\nUsers: 3"
        let result = run([text])
        #expect(result.text == text)
        #expect(!result.stopped)
    }

    @Test func releasesAHeldTailWhenTheStreamEnds() {
        let newline = run(["Done.\n"])
        #expect(newline.text == "Done.\n")
        #expect(!newline.stopped)

        let partial = run(["a\nUs"])
        #expect(partial.text == "a\nUs")
        #expect(!partial.stopped)
    }

    @Test func leavesHTMLAndGenericsAlone() {
        let result = run(["<s>old</s> and Array<Int> a < b"])
        #expect(result.text == "<s>old</s> and Array<Int> a < b")
        #expect(!result.stopped)
    }
}
