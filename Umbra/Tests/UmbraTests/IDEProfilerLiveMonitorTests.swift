import Foundation
import JavaIntelligence
import XCTest
@testable import Umbra

/// The live monitor against a real JVM: found by its `-D` marker through `jps`, read with libproc
/// and `jcmd`, and asked for a snapshot. Skipped without a JDK that ships `jcmd`, `jps` and `jfr`.
@MainActor
final class IDEProfilerLiveMonitorTests: XCTestCase {
    private var directory: URL!
    private var process: Process?

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        process?.terminate()
        try? FileManager.default.removeItem(at: directory)
    }

    private func waitUntil(timeout: Double = 30, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    func testWatchesARealJVMFoundByItsMarkerAndCapturesASnapshot() async throws {
        guard let jdk = JDKLocator().discoverAll()
            .sorted(by: { $0.featureVersion > $1.featureVersion })
            .first(where: { $0.featureVersion >= 17 && $0.javac != nil && $0.jcmd != nil && $0.jps != nil && $0.jfr != nil }) else {
            throw XCTSkip("no JDK 17+ with jcmd, jps and jfr")
        }
        let source = directory.appendingPathComponent("Live.java")
        try """
        import java.util.*;
        public class Live {
            static volatile double sink;
            public static void main(String[] a) throws Exception {
                Thread t = new Thread(() -> { while (true) { sink += Math.sqrt(System.nanoTime()); } }, "spinner");
                t.setDaemon(true); t.start();
                List<byte[]> keep = new ArrayList<>();
                while (true) {
                    keep.add(new byte[128 * 1024]);
                    if (keep.size() > 50) keep.clear();
                    Thread.sleep(20);
                }
            }
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        let compile = Process()
        compile.executableURL = try XCTUnwrap(jdk.javac)
        compile.arguments = ["-d", directory.path, source.path]
        try compile.run()
        compile.waitUntilExit()
        XCTAssertEqual(compile.terminationStatus, 0)

        let runID = "test-\(UUID().uuidString.prefix(8))"
        let run = Process()
        run.executableURL = jdk.home.appendingPathComponent("bin/java")
        run.arguments = [
            JavaLiveCommands.runArgument(runID: runID),
            "-XX:StartFlightRecording=name=umbra,filename=\(directory.path)/rec.jfr,settings=profile,dumponexit=true",
            "-cp", directory.path, "Live"
        ]
        run.standardOutput = FileHandle.nullDevice
        run.standardError = FileHandle.nullDevice
        try run.run()
        process = run

        // No pid is given: the monitor has to find the JVM among the machine's.
        let monitor = IDEProfilerLiveMonitor(
            runID: runID, jcmd: jdk.jcmd, jps: jdk.jps,
            snapshotDirectory: directory.appendingPathComponent("snaps"), knownProcessID: nil
        )
        monitor.start()
        defer { monitor.stop() }

        let attached = await waitUntil { monitor.pid == run.processIdentifier }
        XCTAssertTrue(attached, "\(monitor.status)")
        let read = await waitUntil { monitor.samples.contains { $0.heapUsedBytes != nil && $0.cpuPercent != nil } }
        XCTAssertTrue(read, "\(monitor.samples.suffix(2)) \(monitor.notice ?? "")")

        let sample = try XCTUnwrap(monitor.samples.last { $0.heapUsedBytes != nil && $0.cpuPercent != nil })
        XCTAssertGreaterThan(sample.heapUsedBytes ?? 0, 1_000_000)
        XCTAssertGreaterThan(sample.liveThreads ?? 0, 3)
        XCTAssertGreaterThan(sample.residentBytes ?? 0, 10_000_000)
        // One thread spins flat out: about one core, well under the 40x a wrong time unit would give.
        XCTAssertGreaterThan(sample.cpuPercent ?? 0, 40)
        XCTAssertLessThan(sample.cpuPercent ?? 0, 400)
        XCTAssertNil(monitor.notice)

        let captured = await monitor.captureSnapshot()
        let snapshot = try XCTUnwrap(captured, monitor.notice ?? "")
        XCTAssertTrue(JavaFlightRecordingDetector.isRecording(at: snapshot))
        XCTAssertEqual(monitor.snapshots, [snapshot])
        await monitor.collectGarbage()

        run.terminate()
        run.waitUntilExit()
        let ended = await waitUntil { monitor.status == .ended }
        XCTAssertTrue(ended, "\(monitor.status)")
        XCTAssertNil(IDEProfilerLiveMonitor.taskInfo(of: run.processIdentifier))
    }

    func testWithoutJcmdTheOSSeriesStillComeAndSaySo() async throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        process = sleeper
        let pid = sleeper.processIdentifier
        let monitor = IDEProfilerLiveMonitor(
            runID: "none", jcmd: nil, jps: nil, snapshotDirectory: directory, knownProcessID: { pid }
        )
        monitor.start()
        defer { monitor.stop() }
        let sampled = await waitUntil(timeout: 10) { monitor.samples.count >= 2 }
        XCTAssertTrue(sampled)
        XCTAssertNotNil(monitor.latest?.residentBytes)
        XCTAssertNil(monitor.latest?.heapUsedBytes)
        XCTAssertNotNil(monitor.notice)
        let snapshot = await monitor.captureSnapshot()
        XCTAssertNil(snapshot)
    }
}
