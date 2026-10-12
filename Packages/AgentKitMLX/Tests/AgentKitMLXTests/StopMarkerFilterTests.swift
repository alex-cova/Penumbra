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

    @Test func leavesHTMLAndGenericsAlone() {
        let result = run(["<s>old</s> and Array<Int> a < b"])
        #expect(result.text == "<s>old</s> and Array<Int> a < b")
        #expect(!result.stopped)
    }
}
