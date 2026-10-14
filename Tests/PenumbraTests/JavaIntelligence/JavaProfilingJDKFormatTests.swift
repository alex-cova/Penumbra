import JavaIntelligence
import XCTest

/// The profiler reads `jfr print`, whose text changes between JDKs (a thread's frames, a monitor's
/// address, events that appear only in newer ones). `Fixtures/JavaProfiling/mixed-print-jdk<N>.txt`
/// is that print for `generate/Mixed.java` under each JDK that was installed when
/// `generate/regenerate.sh` last ran, and every one of them must read the same way.
final class JavaProfilingJDKFormatTests: XCTestCase {
    private struct Fixture {
        var name: String
        var text: String
        var featureVersion: Int
    }

    private func fixtures() throws -> [Fixture] {
        let folder = InstrumentationFixtures.url("JavaProfiling", "mixed-print.txt").deletingLastPathComponent()
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("mixed-print-jdk") && $0.hasSuffix(".txt") }
            .sorted()
        return try names.map { name in
            let digits = name.dropFirst("mixed-print-jdk".count).prefix { $0.isNumber }
            return Fixture(
                name: name,
                text: try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8),
                featureVersion: Int(digits) ?? 0
            )
        }
    }

    private func eventCounts(in text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) where line.hasPrefix("jdk.") && line.hasSuffix(" {") {
            counts[String(line.dropLast(2)), default: 0] += 1
        }
        return counts
    }

    func testThereAreFixturesFromSeveralJDKs() throws {
        let versions = try fixtures().map(\.featureVersion)
        XCTAssertGreaterThanOrEqual(versions.count, 3, "regenerate.sh was run with \(versions)")
        XCTAssertTrue(versions.contains(where: { $0 >= 25 }), "a recent LTS or newer: \(versions)")
        XCTAssertTrue(versions.contains(where: { $0 <= 21 }), "the oldest one the profiler is used with here: \(versions)")
    }

    func testEveryJDKsPrintReadsTheSame() throws {
        for fixture in try fixtures() {
            let label = fixture.name
            var parser = JFRTextParser()
            var profile = JavaProfile(symbols: parser.symbols)
            parser.parse(fixture.text) { profile.ingest($0) }
            let counts = eventCounts(in: fixture.text)

            // Nothing in the print is lost on the way in.
            XCTAssertEqual(profile.cpuSamples, counts["jdk.ExecutionSample"], label)
            XCTAssertEqual(profile.cpuSamplesTable.count, profile.cpuSamples, label)
            XCTAssertGreaterThanOrEqual(profile.cpuSamples, 30, "a 600 ms spin at 10 ms: \(label)")
            XCTAssertEqual(profile.allocationSamplesTable.count, counts["jdk.ObjectAllocationSample"], label)
            XCTAssertGreaterThan(profile.allocation.totalSamples, 0, label)
            let waits = ["jdk.ThreadSleep", "jdk.JavaMonitorEnter", "jdk.JavaMonitorWait", "jdk.SocketRead", "jdk.SocketWrite",
                         "jdk.ThreadPark", "jdk.FileRead", "jdk.FileWrite"]
            XCTAssertEqual(profile.contentionSamplesTable.count, waits.reduce(0) { $0 + (counts[$1] ?? 0) }, label)
            XCTAssertEqual(profile.gcPauses.count, counts["jdk.GarbageCollection"], label)
            XCTAssertEqual(profile.heap.count, counts["jdk.GCHeapSummary"], label)
            XCTAssertEqual(profile.cpuLoad.count, counts["jdk.CPULoad"], label)

            // Times are there and in order of the recording.
            let span = try XCTUnwrap(profile.timeSpan, label)
            XCTAssertGreaterThan(span.upperBound - span.lowerBound, 1_500, "the program runs for over 3 s: \(label)")
            XCTAssertTrue(profile.gcPauses.allSatisfy { $0.startMilliseconds != nil }, label)
            XCTAssertTrue(profile.heap.contains(where: \.afterCollection), label)
            XCTAssertTrue(profile.heap.allSatisfy { $0.usedBytes > 0 }, label)
            let load = try XCTUnwrap(profile.cpuLoad.first, label)
            XCTAssertGreaterThan(load.machineTotal, 0, label)
            XCTAssertLessThanOrEqual(load.machineTotal, 1, label)

            // The same stacks and the same kinds of wait.
            let cpu = profile.cpu.foldedStacks(symbols: profile.symbols).joined(separator: "\n")
            XCTAssertTrue(cpu.contains("app.Mixed.main;app.Mixed.spin"), "\(label)\n\(cpu.prefix(600))")
            XCTAssertFalse(cpu.contains("..."), "a frame depth of 128 leaves no stack truncated: \(label)")
            let waitsText = profile.contention.foldedStacks(symbols: profile.symbols).joined(separator: "\n")
            XCTAssertTrue(waitsText.contains("sleeping"), label)
            XCTAssertTrue(waitsText.contains("waiting for java.lang.Object"), label)
            XCTAssertTrue(waitsText.contains("socket read localhost"), label)
            XCTAssertFalse(waitsText.contains("socket read localhost:"), "the port is left out: \(label)")
            let waitThreads = Set(profile.threads(of: .contention).map(\.name))
            XCTAssertTrue(waitThreads.isSuperset(of: ["main", "socket-server", "lock-waiter"]), "\(label) \(waitThreads)")
            XCTAssertTrue(profile.threads(of: .cpu).map(\.name).contains("main"), label)
            XCTAssertEqual(profile.threadsOverLimit, 0, label)

            // The period the recording was made with is read back (profile.jfc: 10 ms; a busy thread
            // gets a sample per period, a little late under load).
            let period = try XCTUnwrap(profile.estimatedCPUSamplePeriodMilliseconds(), label)
            XCTAssertEqual(period, 10, accuracy: 3, label)
        }
    }

    func testEveryJDKsPrintComparesToItselfWithoutChange() throws {
        for fixture in try fixtures() {
            var parser = JFRTextParser()
            var profile = JavaProfile(symbols: parser.symbols)
            parser.parse(fixture.text) { profile.ingest($0) }
            let tree = profile.tree(of: .cpu, thread: nil, range: nil)
            let comparison = JavaProfileComparison.compare(
                baseline: tree, baselineSymbols: profile.symbols, target: tree, targetSymbols: profile.symbols
            )
            XCTAssertTrue(comparison.rows.allSatisfy { $0.baselineSelf == $0.targetSelf }, fixture.name)
            XCTAssertEqual(comparison.change(ofNode: JavaProfileTree.root), 0, accuracy: 0.0001, fixture.name)
        }
    }

    /// Recordings from two JDKs of one program match by method even though their JDK frames differ
    /// (`Thread.run` is at another line in each).
    func testTwoJDKsOfTheSameProgramMatchTheProjectFrames() throws {
        let all = try fixtures()
        let older = try XCTUnwrap(all.first)
        let newer = try XCTUnwrap(all.last)
        func read(_ fixture: Fixture) -> JavaProfile {
            var parser = JFRTextParser()
            var profile = JavaProfile(symbols: parser.symbols)
            parser.parse(fixture.text) { profile.ingest($0) }
            return profile
        }
        let base = read(older), target = read(newer)
        let comparison = JavaProfileComparison.compare(
            baseline: base.tree(of: .cpu, thread: nil, range: nil), baselineSymbols: base.symbols,
            target: target.tree(of: .cpu, thread: nil, range: nil), targetSymbols: target.symbols
        )
        let spin = comparison.rows.first { $0.method.className == "app.Mixed" && $0.method.name == "spin" }
        let row = try XCTUnwrap(spin, "\(older.name) vs \(newer.name)")
        XCTAssertGreaterThan(row.baselineSelf, 0)
        XCTAssertGreaterThan(row.targetSelf, 0, "the method is one row, not two")
    }
}
