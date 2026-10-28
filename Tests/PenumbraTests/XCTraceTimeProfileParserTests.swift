import Foundation
@testable import JavaIntelligence
import XCTest

/// A real `xctrace export` of the `time-profile` table of a Swift program that computes `fib(34)`
/// (`Fixtures/SwiftProfiling/time-profile.xml`).
final class XCTraceTimeProfileParserTests: XCTestCase {
    private func profile() throws -> JavaProfile {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/SwiftProfiling/time-profile.xml")
        return try XCTraceTimeProfileParser.parse(contentsOf: url)
    }

    func testEveryRowIsASampleAndTheStackIsRootFirstInTheTree() throws {
        let profile = try profile()
        XCTAssertEqual(profile.cpuSamples, 18)
        let tree = profile.cpu
        // The root of every stack is a frame the program did not write (`start` in dyld, then `main`).
        let roots = tree.children(of: JavaProfileTree.root).map { profile.symbols.displayName(ofMethod: profile.symbols.frame(tree.frame(of: $0)).method) }
        XCTAssertEqual(roots, ["dyld.start"])
    }

    func testTheHotMethodIsTheRecursiveFunctionAndItsModuleIsTheBinary() throws {
        let profile = try profile()
        let hot = profile.cpu.hotMethods(symbols: profile.symbols)
        let top = try XCTUnwrap(hot.first)
        let method = profile.symbols.methods[Int(top.method)]
        XCTAssertEqual(method.name, "fib(_:)")
        XCTAssertEqual(method.className, "spin")
        XCTAssertGreaterThan(top.selfCount, 5)
        XCTAssertGreaterThanOrEqual(top.totalCount, top.selfCount)
        // Recursion is counted once in the total, as for Java.
        XCTAssertLessThanOrEqual(top.totalCount, profile.cpuSamples)
    }

    func testRepeatedFramesAndBacktracesAreResolvedThroughTheirReferences() throws {
        let profile = try profile()
        let folded = profile.cpu.foldedStacks(symbols: profile.symbols)
        XCTAssertFalse(folded.isEmpty)
        // A stack that recurses names the same frame several times in a row (`<frame ref=…/>`).
        XCTAssertTrue(folded.contains { $0.contains("fib(_:);spin.fib(_:)") || $0.components(separatedBy: "fib(_:)").count > 2 }, "\(folded.prefix(3))")
    }

    func testThreadsAreNamedWithoutTheirProcess() throws {
        let profile = try profile()
        XCTAssertEqual(profile.threads(of: .cpu).map(\.name), ["Main Thread (0x26a632)"])
        XCTAssertEqual(XCTraceTimeProfileParser.threadName(from: "Worker (0x1) (app, pid: 7)"), "Worker (0x1)")
        XCTAssertEqual(XCTraceTimeProfileParser.threadName(from: "Thread 5"), "Thread 5")
        XCTAssertEqual(XCTraceTimeProfileParser.moduleName(from: "libswiftCore.dylib"), "libswiftCore")
        XCTAssertEqual(XCTraceTimeProfileParser.moduleName(from: "spin"), "spin")
    }

    func testTimesAreMillisecondsFromTheFirstSample() throws {
        let profile = try profile()
        let span = try XCTUnwrap(profile.timeSpan)
        XCTAssertEqual(span.lowerBound, 0)
        XCTAssertGreaterThan(span.upperBound, 0)
        XCTAssertLessThan(span.upperBound, 1_000)
    }

    func testOtherDataIsRefused() {
        XCTAssertThrowsError(try XCTraceTimeProfileParser.parse(Data("<a><b></a>".utf8)))
        XCTAssertThrowsError(try XCTraceTimeProfileParser.parse(Data("<trace-query-result/>".utf8))) {
            XCTAssertEqual($0 as? XCTraceTimeProfileParser.ParseError, .noSamples)
        }
    }
}
