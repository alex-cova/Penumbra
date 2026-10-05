import EditorIntelligence
import Foundation
import JavaIntelligence

/// Release-mode cost of refreshing `refs.idx` (docs/JAVA_INDEXING_PLAN.md §0 and §3).
///
/// Builds the identifier index, then times a `build` with nothing changed and a `filesChanged`
/// for one edited file. Each `filesChanged` sample changes one identifier. Prints the shard size.
///
///   swift run -c release PerfHarness java-name-index synthetic [--files N]
///   swift run -c release PerfHarness java-name-index <java-source-directory>
enum JavaNameIndexProfile {
    private static let samples = 8
    private static let vocabulary = [
        "service", "request", "builder", "factory", "handler", "client", "session",
        "config", "mapper", "repository", "controller", "response", "entity", "adapter",
        "provider", "context", "cache", "queue", "worker", "logger", "token", "filter",
        "validator", "converter", "serializer"
    ]

    static func run(pathOrSynthetic: String, files: Int) throws {
        try runBlocking { try await measure(pathOrSynthetic: pathOrSynthetic, files: files) }
    }

    private static func measure(pathOrSynthetic: String, files: Int) async throws {
        let synthetic = pathOrSynthetic == "synthetic" || pathOrSynthetic == "-"
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("perf-names-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let root: URL
        if synthetic {
            root = scratch.appendingPathComponent("src", isDirectory: true)
            try writeSynthetic(count: files, in: root)
            note("=== java name index (synthetic, \(files) files) ===")
        } else {
            root = URL(fileURLWithPath: pathOrSynthetic)
            note("=== java name index (\(root.path)) ===")
        }

        let javaFiles = SourceRoot(directory: root).javaFileURLs()
        guard let edited = javaFiles.first else {
            throw NameIndexProfileFailure(message: "java-name-index found no .java files")
        }
        let original = try String(contentsOf: edited, encoding: .utf8)
        let originalDate = (try? edited.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        defer {
            try? original.write(to: edited, atomically: true, encoding: .utf8)
            if let originalDate {
                try? FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: edited.path)
            }
        }

        let index = JavaNameIndex(paths: JavaIndexPaths(root: scratch.appendingPathComponent("cache")))
        for await _ in await index.build(roots: [root]) {}
        let shard = JavaIndexPaths(root: scratch.appendingPathComponent("cache")).projectNameIndexShard(for: root)

        var unchanged: [Double] = []
        for iteration in 0..<(samples + 1) {
            let start = DispatchTime.now().uptimeNanoseconds
            for await _ in await index.build(roots: [root]) {}
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            if iteration >= 1 { unchanged.append(elapsed) }
        }

        var changed: [Double] = []
        for iteration in 0..<(samples + 1) {
            let text = original + "\nclass PerfMarker\(iteration) {}\n"
            try text.write(to: edited, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_800_000_000 + Double(iteration))],
                ofItemAtPath: edited.path
            )
            let start = DispatchTime.now().uptimeNanoseconds
            _ = await index.filesChanged([edited])
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            if iteration >= 1 { changed.append(elapsed) }
        }

        emit(band: "unchanged", samples: unchanged)
        emit(band: "file_changed", samples: changed)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: shard.path)[.size] as? NSNumber)?.int64Value ?? 0
        note("  files=\(javaFiles.count) shard_bytes=\(bytes)")
    }

    /// `TypeN` files sharing one vocabulary, so posting lists span the tree the way a real project does.
    private static func writeSynthetic(count: Int, in root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for file in 0..<count {
            let url = root.appendingPathComponent("p\(file % 40)/Type\(file).java")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var lines = [
                "package synth.p\(file % 40);",
                "public class Type\(file) {"
            ]
            for (index, word) in vocabulary.enumerated() {
                lines.append("    \(word) field\(index);")
            }
            lines.append("}")
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func emit(band: String, samples: [Double]) {
        let distribution = LatencyDistributionReducer.reduce(samples)
        print("stage java_name_index \(band) count=\(distribution.count) median_s=\(format(distribution.median)) p95_s=\(format(distribution.p95)) worst_s=\(format(distribution.worst))")
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    private static func note(_ text: String) {
        FileHandle.standardError.write("\(text)\n".data(using: .utf8)!)
    }

    private static func runBlocking(_ body: @escaping @Sendable () async throws -> Void) throws {
        let box = BlockingBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                try await body()
                box.result = .success(())
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        try box.result!.get()
    }
}

private final class BlockingBox: @unchecked Sendable {
    var result: Result<Void, Error>?
}

private struct NameIndexProfileFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
