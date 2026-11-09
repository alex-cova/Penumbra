import EditorIntelligence
import Foundation
@_spi(Benchmarks) import JavaIntelligence

/// What one Java completion request allocates while typing in a large file: total bytes and count,
/// the part in allocations of 4 KB or more, the peak of large allocations alive together, and every
/// allocation of 64 KB or more with the code that made it (a whole-document copy shows up as a line
/// of the document's size). One provider is kept across requests, as in the editor; the request's
/// text is built before the window opens, so only the provider's own work is counted.
///
///   swift run -c release PerfHarness java-allocations synthetic [--samples N]
enum JavaAllocationProfile {
    private struct Configuration {
        let lines: Int
        let perClass: Int
        var unicode = false
        var label: String { (perClass == 0 ? "one class" : "classes of \(perClass)") + (unicode ? ", non-ASCII" : ", ASCII") }
    }

    static func run(samples: Int) throws {
        let runner = Runner(samples: samples)
        try runBlocking { try await runner.run() }
    }

    private final class Runner: @unchecked Sendable {
        let samples: Int
        init(samples: Int) { self.samples = samples }

        func run() async throws {
            let (index, directory, jdkVersion) = try await JavaCompletionProfile.prepareIndex(jars: 0)
            defer { try? FileManager.default.removeItem(at: directory) }
            print("=== java allocations per typing request (JDK \(jdkVersion), samples=\(samples)) ===")
            let configurations = [
                Configuration(lines: 5_000, perClass: 100), Configuration(lines: 20_000, perClass: 100),
                Configuration(lines: 120_000, perClass: 100), Configuration(lines: 120_000, perClass: 0),
                Configuration(lines: 5_000, perClass: 100, unicode: true), Configuration(lines: 20_000, perClass: 100, unicode: true),
                Configuration(lines: 120_000, perClass: 100, unicode: true)
            ]
            for configuration in configurations {
                try await measure(configuration, index: index, directory: directory)
            }
        }

        private func measure(_ configuration: Configuration, index: JavaIndex, directory: URL) async throws {
            JavaCompletionProfile.fillerPerClass = configuration.perClass
            JavaCompletionProfile.unicodeHeader = configuration.unicode
            let methods = configuration.lines / 5
            let provider = JavaCompletionProvider(index: index)
            var reports: [AllocationTrace.Report] = []
            var seconds: [Double] = []
            let warmUp = 4
            for iteration in 0..<(warmUp + samples) {
                let typed = "int typed\(iteration) = \(iteration);\n        "
                let before = """
                \(JavaCompletionProfile.header)package com.perf.app;

                import com.perf.p0.*;
                import java.util.*;
                import java.util.stream.*;

                class Completing {
                \(JavaCompletionProfile.filler(methods))
                    void test(User user, List<User> users) {
                        \(typed)user.getAddress().
                """
                let text = before + "\n    }\n}\n"
                let url = directory.appendingPathComponent("Completing.java")
                let position = TextPosition(
                    line: before.components(separatedBy: "\n").count - 1,
                    column: (before.components(separatedBy: "\n").last ?? "").utf16.count,
                    utf16Offset: (before as NSString).length
                )
                let document = Document(
                    id: DocumentID(), url: url, displayName: "Completing.java",
                    contentSnapshot: TextSnapshot(version: iteration, text: text),
                    selection: Selection(range: TextRange(start: position, end: position)), cursor: Cursor(position: position),
                    viewport: Viewport(x: 0, y: 0, width: 100, height: 100), languageIdentifier: "java"
                )
                let context = makeCompletionContext(document: document, trigger: .keystroke("."))
                let stream = provider.provideUpdates(context: context)

                let counting = iteration >= warmUp
                let start = DispatchTime.now().uptimeNanoseconds
                if counting { AllocationTrace.start() }
                for await _ in stream {}
                let report = counting ? AllocationTrace.stop() : AllocationTrace.Report()
                if counting {
                    reports.append(report)
                    seconds.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
                }
            }
            guard let last = reports.last else { return }
            func spread(_ values: [Int]) -> String {
                let sorted = values.sorted()
                return "median \(Self.bytes(sorted[sorted.count / 2])) (min \(Self.bytes(sorted[0])), max \(Self.bytes(sorted[sorted.count - 1])))"
            }
            let sortedSeconds = seconds.sorted()
            print("size lines=\(configuration.lines) shape=\(configuration.label) text=\(Self.bytes(last.large.map(\.size).max() ?? 0)) request_ms=\(String(format: "%.3f", sortedSeconds[sortedSeconds.count / 2] * 1000)) (traced, includes hook overhead)")
            print("  allocated \(spread(reports.map(\.totalBytes))), \(reports.map(\.totalCount).sorted()[reports.count / 2]) allocations; in allocations of 4 KB+: \(spread(reports.map(\.bytesInAllocationsOfAtLeast4K)))")
            print("  peak of large allocations alive together: \(spread(reports.map(\.peakLiveLargeBytes)))")
            // The same stack allocating the same size is one line with a count.
            var groups: [(size: Int, names: [String], count: Int)] = []
            for allocation in last.large {
                let names = AllocationTrace.describe(allocation.frames)
                if let at = groups.firstIndex(where: { $0.size == allocation.size && $0.names == names }) {
                    groups[at].count += 1
                } else {
                    groups.append((allocation.size, names, 1))
                }
            }
            for group in groups {
                print("    \(Self.bytes(group.size).padding(toLength: 9, withPad: " ", startingAt: 0)) x\(group.count)  \(group.names.joined(separator: " < "))")
            }
        }

        static func bytes(_ count: Int) -> String {
            count >= 1 << 20 ? String(format: "%.2f MB", Double(count) / Double(1 << 20))
                : count >= 1 << 10 ? String(format: "%.1f KB", Double(count) / 1024) : "\(count) B"
        }
    }

    private static func runBlocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        nonisolated(unsafe) var result: Result<T, Error>?
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do { result = .success(try await body()) } catch { result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try result!.get()
    }
}
