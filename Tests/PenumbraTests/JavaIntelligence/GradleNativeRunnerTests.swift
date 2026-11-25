import Foundation
import Testing
@testable import JavaIntelligence

struct GradleNativeRunnerTests {
    @Test func journalUsesOccurrenceIdentityAndKeepsTerminalOutcomes() async throws {
        try await withDirectory { directory in
            let id = UUID()
            let session = GradleTestSession(id: id, directory: directory)
            let file = directory.appendingPathComponent("events.jsonl")
            let records = [
                record(id, 7, "testFinished", node: "a", parent: "late-parent", outcome: "failed"),
                record(id, 5, "testStarted", node: "a"),
                record(id, 7, "testFinished", node: "a", outcome: "passed"),
                record(id, 8, "suiteStarted", node: "late-parent"),
                record(id, 9, "testStarted", build: "/other", node: "b"),
                record(UUID(), 10, "testStarted", node: "wrong-session")
            ]
            let lines = try records.map { try JSONSerialization.data(withJSONObject: $0) }
            var initial = Data()
            for line in lines.dropLast() { initial.append(line); initial.append(0x0A) }
            initial.append(lines.last!.prefix(11))
            try initial.write(to: file)
            let first = await session.poll()
            #expect(first.counts[.failed] == 1)
            #expect(first.counts[.running] == 1)
            #expect(first.nodes.first { $0.id == "a" }?.event.parentID == "late-parent")
            #expect(first.nodes.first { $0.id == "b" }?.event.build == "/other")
            let fileHandle = try FileHandle(forWritingTo: file)
            try fileHandle.seekToEnd()
            try fileHandle.write(contentsOf: lines.last!.dropFirst(11) + Data([0x0A]))
            try fileHandle.close()
            let final = await session.seal(unfinished: .cancelled)
            #expect(final.issues == 1)
            #expect(final.counts[.running] == 0)
            #expect(final.counts[.cancelled] == 1)
            #expect(final.nodes.map(\.id) == ["late-parent", "b"])
            #expect(await session.poll().nodes.isEmpty)
        }
    }

    @Test func workerCrashChangesSyntheticSkipAndKeepsOrdinarySkip() async throws {
        try await withDirectory { directory in
            let id = UUID()
            let session = GradleTestSession(id: id, directory: directory)
            var skipped = record(id, 175, "testFinished", node: "during-crash", outcome: "skipped")
            skipped["durationMs"] = 382
            var failedTask = record(id, 185, "taskFinished", node: "task", outcome: "failed")
            failedTask["failure"] = ["type": "org.gradle.process.ProcessExecutionException",
                                     "stackTrace": "Gradle Test Executor 16 exited with status 23"]
            let lines = [record(id, 1, "testFinished", node: "ordinary-skip", outcome: "skipped"), skipped, failedTask]
            for line in lines {
                let data = try JSONSerialization.data(withJSONObject: line)
                try await session.ingest(JSONDecoder().decode(GradleTestEvent.self, from: data))
            }
            let update = await session.seal(unfinished: .unknown)
            #expect(update.counts[.aborted] == 1)
            #expect(update.counts[.skipped] == 1)
        }
    }

    @Test func logPreservesBytesAndSourceAcrossPageBoundaries() async throws {
        try await withDirectory { root in
            let directory = root.appendingPathComponent("session")
            let log = try GradleSessionLog(directory: directory)
            let prefix = Data(repeating: 0x61, count: 256 * 1024 - 2)
            try log.append(prefix + Data("ab".utf8), stream: .stdout)
            try log.append(Data("cdé\r\n".utf8), stream: .stderr)
            let found = try log.find("abcd")
            let match = try #require(found)
            #expect(match.lowerBound == UInt64(prefix.count))
            let ranges = try log.read(match)
            #expect(ranges.map(\.0) == [.stdout, .stderr])
            #expect(ranges.map(\.1) == [Data("ab".utf8), Data("cd".utf8)])
            let export = root.appendingPathComponent("export")
            try log.export(to: export)
            #expect(try Data(contentsOf: export) == prefix + Data("abcdé\r\n".utf8))
            let restored = try GradleSessionLog(reading: directory)
            #expect(restored.snapshot == log.snapshot)
            #expect(try restored.find("é")?.lowerBound == UInt64(prefix.count + 4))
        }
    }

    @Test func oversizedLinesKeepUTF8AndFollowingLinesIntact() {
        let receiver = TestLines()
        let splitter = GradleOutputLineSplitter(handler: receiver.append)
        let original = String(repeating: "é", count: 20_000)
        let data = Data(original.utf8)
        splitter.append(data.prefix(16383), stream: .stdout)
        splitter.append(Data(data.dropFirst(16383)) + Data("\r".utf8), stream: .stdout)
        splitter.append(Data("\nnext\rupdate\n".utf8), stream: .stdout)
        splitter.flush()
        let lines = receiver.lines
        #expect(lines.suffix(2) == ["next", "update"])
        #expect(lines.dropLast(2).joined() == original)
        #expect(lines.allSatisfy { $0.utf8.count <= 16 * 1024 })
    }

    @Test func reportsRejectUnchangedAndAmbiguouslyOwnedFiles() async throws {
        try await withDirectory { directory in
            let report = directory.appendingPathComponent("TEST-example.xml")
            let original = """
            <testsuite><testcase classname="Example" name="one"/><system-out>suite only</system-out></testsuite>
            """
            try original.write(to: report, atomically: true, encoding: .utf8)
            let owners = [":a:test": [directory]]
            let snapshot = GradleTestReports(directoriesByTask: owners)
            #expect(snapshot.reconcile(excluding: [], didRun: [":a:test"]).isEmpty)
            try original.replacingOccurrences(of: "name=\"one\"/>", with: "name=\"two\"><skipped/></testcase>")
                .write(to: report, atomically: true, encoding: .utf8)
            let rows = snapshot.reconcile(excluding: [], didRun: [":a:test"])
            #expect(rows.map(\.task) == [":a:test"])
            #expect(rows.first?.result.status == .skipped)
            #expect(rows.first?.result.output == nil)
            #expect(snapshot.reconcile(excluding: [":a:test"], didRun: [":a:test"]).isEmpty)
            #expect(snapshot.reconcile(excluding: [], didRun: []).isEmpty)
            let ambiguous = GradleTestReports(directoriesByTask: [":a:test": [directory], ":b:test": [directory]])
            try original.write(to: report, atomically: true, encoding: .utf8)
            #expect(ambiguous.reconcile(excluding: [], didRun: [":a:test", ":b:test"]).isEmpty)
        }
    }

    @Test func kotlinDiscoveryRequiresKnownJVMTestAnnotations() throws {
        let source = """
        package example
        import org.junit.jupiter.api.Test as JupiterTest
        import org.junit.jupiter.params.ParameterizedTest

        class Sample {
            @JupiterTest fun checks() {}
            @ParameterizedTest fun values(input: Int) {}
            @Test fun unknownAnnotation() {}

            class Nested {
                @org.junit.Test fun inner() {}
            }
        }

        @JupiterTest fun topLevel() {}
        """
        let tests = KotlinJVMTestDiscovery.discover(source: source, url: URL(fileURLWithPath: "/tmp/Sample.kt"))
        #expect(tests["example.Sample"]?.map(\.methodName) == ["checks", "values"])
        #expect(tests["example.Sample$Nested"]?.map(\.methodName) == ["inner"])
    }

    @Test func retryKeepsSelectorsWithTheirOwnTasksAndPreservesCacheChoice() {
        let plan = GradleTestRetryPlan.granular(targets: [
            .init(task: ":b:test", filter: "example.Duplicate.other"),
            .init(task: ":a:test", filter: "example.Duplicate.first")
        ], arguments: ["--continue", "--tests", "old", "--configuration-cache", "-Px=1"])
        #expect(plan.map(\.tasks) == [[":a:test", "--rerun"], [":b:test", "--rerun"]])
        #expect(plan[0].arguments == ["--tests", "example.Duplicate.first", "--continue", "--configuration-cache", "-Px=1"])
        #expect(plan[1].arguments[1] == "example.Duplicate.other")
        #expect(GradleTestSidecar.configurationCacheEnabled(arguments: ["--no-configuration-cache", "--configuration-cache"]))
        #expect(!GradleTestSidecar.configurationCacheEnabled(arguments: ["--configuration-cache", "--no-configuration-cache"]))
        #expect(GradleTestRetryPlan.complete(tasks: [":a:test", ":b:test"], arguments: [])?.tasks ==
                [":a:test", "--rerun", ":b:test", "--rerun"])
    }

    @Test func restartInterruptsUnsealedHistoryAndRetentionProtectsUsers() async throws {
        try await withDirectory { directory in
            let root = directory.appendingPathComponent("project")
            let original = GradleTestHistory(directory: directory)
            let written = try await original.begin(root: root, tasks: [":test"])
            let active = try await original.begin(root: root, tasks: [":other"], original: written.id)
            #expect(await original.acquire(written.id))
            try await original.evict(days: 0, bytes: 0)
            #expect(await original.list(root: root).count == 2)
            let reopened = GradleTestHistory(directory: directory)
            let history = await reopened.list(root: root)
            #expect(history.allSatisfy { $0.state == .interrupted })
            #expect(history.first { $0.id == active.id }?.original == written.id)
            await original.release(written.id)
        }
    }

    private func record(_ id: UUID, _ sequence: Int, _ kind: String, build: String = "/root",
                        node: String, parent: String? = nil, outcome: String? = nil) -> [String: Any] {
        var record: [String: Any] = ["version": 1, "sessionID": id.uuidString, "sequence": sequence,
                                      "timestamp": sequence, "kind": kind, "build": build, "task": ":app:test",
                                      "nodeID": node, "name": "same label", "className": "pkg.Duplicate"]
        record["parentID"] = parent
        record["outcome"] = outcome
        return record
    }

    private func withDirectory(_ action: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await action(directory)
    }
}

private final class TestLines: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    var lines: [String] { lock.withLock { items } }
    func append(_ line: GradleOutputLine) { lock.withLock { items.append(line.text) } }
}
