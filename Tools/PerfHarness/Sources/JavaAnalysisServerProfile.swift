import Foundation
import JavaIntelligence

/// Release-mode cost of one analysis-server `check` (warm `javac` over a JSON-lines stdio
/// server): the cold check that starts the JVM and opens the module's file manager, then the
/// warm checks a keystroke actually waits for. Compare against the PR3 exit (warm p50 idle to
/// `javac` errors at or under 300 ms on a 2k-line file).
///
///   swift run -c release PerfHarness java-analysis-server synthetic [--lines N] [--samples N]
///   swift run -c release PerfHarness java-analysis-server /path/to/Big.java
///
/// The server jar is the one `Example/Umbra/Tools/JavaAnalysisServer/build.sh` builds; when it
/// is missing the profile builds it into a temporary directory first.
enum JavaAnalysisServerProfile {
    static func run(pathOrSynthetic: String, lines: Int, samples: Int) throws {
        let isSynthetic = pathOrSynthetic == "synthetic" || pathOrSynthetic == "-"
        let source = isSynthetic
            ? syntheticJava(lines: lines)
            : String(decoding: try Data(contentsOf: URL(fileURLWithPath: pathOrSynthetic)), as: UTF8.self)
        let lineCount = source.utf8.reduce(1) { $0 + ($1 == 10 ? 1 : 0) }
        let (cold, warm) = try runBlocking {
            try await measure(source: source, samples: samples)
        }
        let sorted = warm.sorted()
        let median = sorted[sorted.count / 2]
        print("stage java_analysis_server lines=\(lineCount) count=\(sorted.count) cold_s=\(format(cold)) warm_median_s=\(format(median)) warm_worst_s=\(format(sorted.last ?? 0))")
    }

    private static func measure(source: String, samples: Int) async throws -> (cold: Double, warm: [Double]) {
        guard let jdk = JDKLocator().select() else {
            throw AnalysisServerProfileFailure(message: "java-analysis-server needs an installed JDK")
        }
        let jar = try ensureServerJar()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "perf-java-analysis-server-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Perf.java")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let client = JavaAnalysisServerClient(configuration: JavaAnalysisServerConfiguration(
            jarURL: jar, javaExecutable: jdk.home.appendingPathComponent("bin/java")))
        defer { Task { await client.shutdown() } }
        try await client.configure(JavaAnalysisServerModule(moduleId: "perf", sourcepath: [directory]))

        let coldStart = DispatchTime.now().uptimeNanoseconds
        _ = try await client.check(moduleId: "perf", file: file, text: source)
        let cold = Double(DispatchTime.now().uptimeNanoseconds - coldStart) / 1e9

        var warm: [Double] = []
        for _ in 0 ..< samples {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try await client.check(moduleId: "perf", file: file, text: source)
            warm.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
        }
        return (cold, warm)
    }

    /// The repo-built jar when present, else a fresh `build.sh` into a temporary directory.
    private static func ensureServerJar() throws -> URL {
        // #filePath is Tools/PerfHarness/Sources/<file>; four levels up is the repo root.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let built = root.appendingPathComponent("Example/Umbra/Tools/JavaAnalysisServer/build/java-analysis-server.jar")
        if FileManager.default.fileExists(atPath: built.path) { return built }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("perf-analysis-server-build-\(UUID().uuidString)")
        let build = root.appendingPathComponent("Example/Umbra/Tools/JavaAnalysisServer/build.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [build.path]
        var environment = ProcessInfo.processInfo.environment
        environment["BUILD_OUT"] = out.path
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AnalysisServerProfileFailure(message: "build.sh failed")
        }
        return out.appendingPathComponent("java-analysis-server.jar")
    }

    /// One package of classes with real cross-references, so the check attributes instead of
    /// only parsing. Matches the inspections synthetic in shape but stays single-file.
    static func syntheticJava(lines target: Int) -> String {
        var out = ["import java.util.*;", ""]
        var classIndex = 0
        while out.count < target {
            out.append("class Service\(classIndex) {")
            out.append("    private final Map<String, Integer> cache = new HashMap<>();")
            out.append("    int[] data = new int[4];")
            for method in 0 ..< 8 {
                out.append("")
                out.append("    public int compute\(method)(String key, String other, int limit, int[] copy) {")
                out.append("        int total = 0;")
                out.append("        for (int i = 0; i < limit; i++) {")
                out.append("            total += key.length() * i + \(method);")
                out.append("        }")
                out.append("        if (key == other) total++;")
                out.append("        if (data == copy) total--;")
                out.append("        String text = \"\" + total;")
                out.append("        int biggest = total > limit ? total : limit;")
                out.append("        return cache.getOrDefault(key, biggest + text.length());")
                out.append("    }")
            }
            out.append("}")
            out.append("")
            classIndex += 1
        }
        return out.joined(separator: "\n")
    }

    private static func format(_ value: Double) -> String { String(format: "%.6f", value) }

    private static func runBlocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let box = AnalysisServerBlockingBox<T>()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.result = .success(try await body()) } catch { box.result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try box.result!.get()
    }
}

private final class AnalysisServerBlockingBox<T: Sendable>: @unchecked Sendable {
    var result: Result<T, Error>?
}

private struct AnalysisServerProfileFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
