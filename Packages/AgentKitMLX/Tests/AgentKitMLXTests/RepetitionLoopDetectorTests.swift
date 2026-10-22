import Testing
@testable import AgentKitMLX

@Suite struct RepetitionLoopDetectorTests {
    private func tripped(_ chunks: [String]) -> Bool {
        var detector = RepetitionLoopDetector()
        for chunk in chunks where detector.consume(chunk) { return true }
        return false
    }

    @Test func catchesAShortUnitRepeatedTokenByToken() {
        // What Umbra showed: the model cycling one word.
        #expect(tripped(["Hi! "] + Array(repeating: "ACHI ", count: 30)))
    }

    @Test func catchesALoopThatArrivesInOneChunk() {
        #expect(tripped([String(repeating: "ACHI ", count: 40)]))
    }

    @Test func catchesASingleRepeatedLetter() {
        #expect(tripped([String(repeating: "a", count: 100)]))
    }

    @Test func catchesARepeatedPunctuationMark() {
        // A lone quote cycling, token by token.
        #expect(tripped(["SSH is a protocol. "] + Array(repeating: "'", count: 100)))
        #expect(tripped([String(repeating: "'\"", count: 60)]))
    }

    @Test func catchesALongerUnit() {
        #expect(tripped([String(repeating: "I am sorry, I cannot. ", count: 12)]))
    }

    @Test func letsOrdinaryTextThrough() {
        let prose = "Umbra opens files from the File menu. Use Open to pick one, or drag it onto the window. "
        #expect(!tripped([prose + prose]))
    }

    @Test func letsRulesAndIndentationThrough() {
        #expect(!tripped(["Title\n" + String(repeating: "=", count: 120) + "\n"]))
        #expect(!tripped([String(repeating: " ", count: 120) + "x"]))
        #expect(!tripped([String(repeating: "\n", count: 120)]))
        #expect(!tripped(["| a | b |\n" + String(repeating: "|---", count: 30) + "|\n"]))
    }

    @Test func aShortRunIsNotALoop() {
        #expect(!tripped([String(repeating: "ok ", count: 9)]))
    }

    @Test func staysTrippedOnceFound() {
        var detector = RepetitionLoopDetector()
        let first = detector.consume(String(repeating: "ACHI ", count: 40))
        let second = detector.consume("something else")
        #expect(first)
        #expect(second)
    }
}
