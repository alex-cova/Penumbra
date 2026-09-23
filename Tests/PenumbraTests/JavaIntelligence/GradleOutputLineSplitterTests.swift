import XCTest
@testable import JavaIntelligence

/// `GradleOutputLineSplitter` turns the raw byte chunks a `Pipe` readability handler delivers
/// (arbitrary boundaries, not line-aligned) into complete lines. These tests feed it chunks split
/// at deliberately awkward points to pin down that contract.
final class GradleOutputLineSplitterTests: XCTestCase {
    func testEmitsWholeLineDeliveredInOneChunk() {
        let received = Collector()
        let splitter = GradleOutputLineSplitter(handler: received.handler)
        splitter.append(Data("hello world\n".utf8), stream: .stdout)
        XCTAssertEqual(received.lines.map(\.text), ["hello world"])
    }

    func testLineSplitAcrossTwoChunksIsJoinedBeforeEmitting() {
        let received = Collector()
        let splitter = GradleOutputLineSplitter(handler: received.handler)
        splitter.append(Data("> Task :umbraProj".utf8), stream: .stdout)
        XCTAssertTrue(received.lines.isEmpty, "no line should be emitted until the newline arrives")
        splitter.append(Data("ectModel\n".utf8), stream: .stdout)
        XCTAssertEqual(received.lines.map(\.text), ["> Task :umbraProjectModel"])
    }

    func testMultibyteCharacterSplitAcrossChunksDecodesCorrectly() {
        // "café\n" as UTF-8: the 'é' is 2 bytes (0xC3 0xA9); split the chunk between them.
        let full = Array("café\n".utf8)
        let splitPoint = full.count - 2 // right before the 2-byte 'é'
        let received = Collector()
        let splitter = GradleOutputLineSplitter(handler: received.handler)
        splitter.append(Data(full[0..<splitPoint]), stream: .stdout)
        splitter.append(Data(full[splitPoint...]), stream: .stdout)
        XCTAssertEqual(received.lines.map(\.text), ["café"])
    }

    func testTrailingCarriageReturnIsStripped() {
        let received = Collector()
        let splitter = GradleOutputLineSplitter(handler: received.handler)
        splitter.append(Data("windows-style\r\n".utf8), stream: .stdout)
        XCTAssertEqual(received.lines.map(\.text), ["windows-style"])
    }

    func testFlushEmitsTrailingPartialLineWithNoNewline() {
        let received = Collector()
        let splitter = GradleOutputLineSplitter(handler: received.handler)
        splitter.append(Data("BUILD SUCCESSFUL".utf8), stream: .stdout)
        XCTAssertTrue(received.lines.isEmpty)
        splitter.flush()
        XCTAssertEqual(received.lines.map(\.text), ["BUILD SUCCESSFUL"])
    }

    func testFlushWithNothingBufferedEmitsNothing() {
        let received = Collector()
        let splitter = GradleOutputLineSplitter(handler: received.handler)
        splitter.append(Data("complete line\n".utf8), stream: .stdout)
        splitter.flush()
        XCTAssertEqual(received.lines.map(\.text), ["complete line"])
    }

    func testStdoutAndStderrBuffersAreIndependent() {
        let received = Collector()
        let splitter = GradleOutputLineSplitter(handler: received.handler)
        splitter.append(Data("out-partial".utf8), stream: .stdout)
        splitter.append(Data("err-line\n".utf8), stream: .stderr)
        XCTAssertEqual(received.lines.map(\.text), ["err-line"])
        XCTAssertEqual(received.lines.map(\.stream), [.stderr])
        splitter.append(Data("-rest\n".utf8), stream: .stdout)
        XCTAssertEqual(received.lines.map(\.text), ["err-line", "out-partial-rest"])
    }

    func testNilHandlerDoesNotCrashAndDoesNoWork() {
        let splitter = GradleOutputLineSplitter(handler: nil)
        splitter.append(Data("anything\n".utf8), stream: .stdout)
        splitter.flush()
        // No assertion beyond "did not crash" -- there is nowhere for output to be observed.
    }

    // MARK: - Helpers

    /// Everything here runs synchronously on the test's own thread (no real process involved), but
    /// `GradleOutputHandler` is `@Sendable`, so the collector still has to prove it's safe to share.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var storedLines: [GradleOutputLine] = []
        var lines: [GradleOutputLine] {
            lock.lock()
            defer { lock.unlock() }
            return storedLines
        }
        var handler: GradleOutputHandler {
            { [self] line in
                lock.lock()
                storedLines.append(line)
                lock.unlock()
            }
        }
    }
}
