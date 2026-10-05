import Foundation
import EditorIntelligence
import JavaIntelligence

/// Release-mode latency for `JavaCompletionProvider` (docs/JAVA_COMPLETION_PLAN.md §4.5).
///
/// Indexes the JDK's `ct.sym` plus a generated project, then times the first and the last
/// `CompletionUpdate` for a set of representative sites, in a small file and in a 5k-line file.
/// Prints `stage` rows like `InteractiveProfile` and one `budget` row per gate:
///
///   swift run -c release PerfHarness java-completion synthetic [--jars N]
enum JavaCompletionProfile {
    private static let samples = 12
    private static let packageCount = 20
    private static let classesPerPackage = 25
    /// A few hundred classes per synthetic JAR shard. `--jars 200` is a Spring Boot-sized classpath.
    private static let classesPerJar = 400
    private static let jarWords = ["Default", "Abstract", "Http", "Json", "Request", "Service", "Builder", "Factory", "Exception"]

    private struct Site {
        let name: String
        let before: String
        let after: String
    }

    /// Code inside `void test(...) { … }` of the completing class, split at the caret.
    private static let sites: [Site] = [
        Site(name: "member_access", before: "user.getAddress().", after: ""),
        Site(name: "member_prefix", before: "user.getN", after: ""),
        Site(name: "lambda_chain", before: "users.stream().filter(u -> u.isActive()).map(u -> u.", after: ")"),
        Site(name: "class_name_one", before: "S", after: ""),
        Site(name: "class_name_short", before: "Str", after: ""),
        Site(name: "class_name_long", before: "ArrayLi", after: ""),
        Site(name: "class_name_hump", before: "NPE", after: ""),
        Site(name: "new_expected", before: "List<User> result = new Arr", after: ""),
        Site(name: "statement_expected", before: "String s = ", after: "")
    ]

    static func run(jars: Int = 0) throws {
        let result = try runBlocking { try await measure(jars: jars) }
        var firstAll: [Double] = []
        var finalAll: [Double] = []
        for (name, band) in result.small {
            emit(stage: "java_completion_fast", band: name, samples: band.first)
            emit(stage: "java_completion_final", band: name, samples: band.final)
            firstAll += band.first
            finalAll += band.final
        }
        var largeFirst: [Double] = []
        for (name, band) in result.large {
            emit(stage: "java_completion_large_file", band: name, samples: band.first)
            largeFirst += band.first
        }
        budget("java_completion_fast", target: 0.050, samples: firstAll)
        budget("java_completion_final", target: 0.150, samples: finalAll)
        budget("java_completion_large_file", target: 0.100, samples: largeFirst)
    }

    // MARK: - Measurement

    private struct Band {
        var first: [Double] = []
        var final: [Double] = []
    }

    private struct Result {
        var small: [(String, Band)] = []
        var large: [(String, Band)] = []
    }

    private static func measure(jars: Int) async throws -> Result {
        guard let jdk = JDKLocator().select() else {
            throw ProfileFailure(message: "java-completion needs an installed JDK")
        }
        note("=== java completion profile (JDK \(jdk.featureVersion), jars=\(jars)) ===")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("perf-java-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let index = JavaIndex()
        let jdkShard = directory.appendingPathComponent("jdk.idx")
        try JavaIndexShardWriter().write(try JDKCtSymRoot(installation: jdk).readStubs(), stamp: JavaStamp(size: 0, modificationDate: 0), to: jdkShard)
        let projectShard = directory.appendingPathComponent("project.idx")
        try JavaIndexShardWriter().write(try writeProject(in: directory), stamp: JavaStamp(size: 0, modificationDate: 0), to: projectShard)
        var sources: [JavaIndex.Source] = [
            .init(precedence: 1, reader: try JavaIndexShardReader(url: projectShard), shardPath: projectShard.path),
            .init(precedence: 3, reader: try JavaIndexShardReader(url: jdkShard))
        ]
        sources += try writeJarShards(count: jars, in: directory)
        let nameCount = sources.reduce(0) { $0 + $1.reader.allQualifiedNames.count }
        let started = DispatchTime.now().uptimeNanoseconds
        await index.setSources(sources)
        let setSources = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
        note("  names=\(nameCount) sources=\(sources.count) set_sources_s=\(format(setSources))")

        var result = Result()
        for site in sites {
            result.small.append((site.name, try await sample(site: site, fillerMethods: 0, index: index, directory: directory)))
        }
        for site in sites where site.name == "member_access" || site.name == "class_name_short" || site.name == "lambda_chain" {
            // Roughly 5k lines: each filler method is 5 lines.
            result.large.append((site.name, try await sample(site: site, fillerMethods: 1_000, index: index, directory: directory)))
        }
        // Typing: one provider across requests while the document changes a little each time,
        // which is what the editor does and what the incremental reparse is for.
        let typing = sites.first { $0.name == "member_access" }!
        result.large.append(("member_access_typing", try await sample(site: typing, fillerMethods: 1_000, index: index, directory: directory, reuseProvider: true)))
        return result
    }

    private static func sample(site: Site, fillerMethods: Int, index: JavaIndex, directory: URL, reuseProvider: Bool = false) async throws -> Band {
        var band = Band()
        let shared = JavaCompletionProvider(index: index)
        for iteration in 0..<(samples + 2) {
            let typed = reuseProvider ? "int typed\(iteration) = \(iteration);\n        " : ""
            let before = """
        package com.perf.app;

        import com.perf.p0.*;
        import java.util.*;
        import java.util.stream.*;

        class Completing {
        \(filler(fillerMethods))
            void test(User user, List<User> users) {
                \(typed)\(site.before)
        """
            let after = "\(site.after)\n    }\n}\n"
            let text = before + after
            let url = directory.appendingPathComponent("Completing.java")
            let position = TextPosition(
                line: before.components(separatedBy: "\n").count - 1,
                column: (before.components(separatedBy: "\n").last ?? "").utf16.count,
                utf16Offset: (before as NSString).length
            )
            // By default a fresh provider per sample, so nothing carries over from the previous
            // request's parse.
            let provider = reuseProvider ? shared : JavaCompletionProvider(index: index)
            let document = Document(
                id: DocumentID(), url: url, displayName: "Completing.java",
                contentSnapshot: TextSnapshot(version: iteration, text: text),
                selection: Selection(range: TextRange(start: position, end: position)), cursor: Cursor(position: position),
                viewport: Viewport(x: 0, y: 0, width: 100, height: 100), languageIdentifier: "java"
            )
            let context = makeCompletionContext(document: document, trigger: .keystroke(String(site.before.last ?? " ")))
            let start = DispatchTime.now().uptimeNanoseconds
            var first: Double?
            var last = 0.0
            for await _ in provider.provideUpdates(context: context) {
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
                if first == nil { first = elapsed }
                last = elapsed
            }
            // The first two runs warm caches (stub decoding, class-name tables).
            guard iteration >= 2 else { continue }
            band.first.append(first ?? last)
            band.final.append(last)
        }
        return band
    }

    private static func filler(_ count: Int) -> String {
        (0..<count).map { index in
            """
                int filler\(index)(int value) {
                    int doubled = value * 2;
                    return doubled + \(index);
                }

            """
        }.joined()
    }

    /// `com.perf.p<N>.Type<M>` classes with a few members each, plus `User`/`Address`.
    private static func writeProject(in directory: URL) throws -> [JavaClassStub] {
        var stubs: [JavaClassStub] = []
        func add(_ source: String, _ relativePath: String) throws {
            let url = directory.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try source.write(to: url, atomically: true, encoding: .utf8)
            stubs += JavaSourceStubBuilder.build(source: source, url: url).classes
        }
        try add("""
        package com.perf.p0;
        public class User {
            public String getName() { return ""; }
            public Address getAddress() { return null; }
            public boolean isActive() { return true; }
        }
        """, "src/com/perf/p0/User.java")
        try add("""
        package com.perf.p0;
        public class Address {
            public String getCity() { return ""; }
            public int getZip() { return 0; }
        }
        """, "src/com/perf/p0/Address.java")
        for package in 0..<packageCount {
            for type in 0..<classesPerPackage {
                try add("""
                package com.perf.p\(package);
                public class Type\(package)x\(type) {
                    public String name\(type)() { return ""; }
                    public int count\(type)() { return 0; }
                    public Type\(package)x\(type) next() { return this; }
                }
                """, "src/com/perf/p\(package)/Type\(package)x\(type).java")
            }
        }
        return stubs
    }

    /// Precedence-2 shards, each a few hundred classes under its own packages. Some names are nested.
    private static func writeJarShards(count: Int, in directory: URL) throws -> [JavaIndex.Source] {
        guard count > 0 else { return [] }
        var sources: [JavaIndex.Source] = []
        sources.reserveCapacity(count)
        let words = jarWords
        let wordCount = words.count
        for jar in 0..<count {
            var stubs: [JavaClassStub] = []
            stubs.reserveCapacity(classesPerJar)
            let origin = URL(fileURLWithPath: "/synthetic/jar\(jar).jar")
            for index in 0..<classesPerJar {
                let packageName = "com.synth.j\(jar).p\(index / 20)"
                let w0 = words[index % wordCount]
                let w1 = words[(index / wordCount) % wordCount]
                let w2 = words[(index / (wordCount * wordCount)) % wordCount]
                let simple: String
                let qualified: String
                let binary: String
                let outer: String?
                if index % 7 == 0 {
                    let outerSimple = "\(w0)\(w1)"
                    simple = w2
                    outer = "\(packageName).\(outerSimple)"
                    qualified = "\(outer!).\(simple)"
                    binary = "\(packageName).\(outerSimple)$\(simple)"
                } else {
                    simple = "\(w0)\(w1)\(w2)"
                    qualified = "\(packageName).\(simple)"
                    binary = qualified
                    outer = nil
                }
                stubs.append(JavaClassStub(
                    binaryName: binary, qualifiedName: qualified, simpleName: simple, packageName: packageName,
                    outerQualifiedName: outer, kind: .classKind, modifiers: [.publicFlag], origin: .jar(origin)
                ))
            }
            let shard = directory.appendingPathComponent("jar-\(jar).idx")
            try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: shard)
            sources.append(.init(precedence: 2, reader: try JavaIndexShardReader(url: shard), shardPath: shard.path))
        }
        return sources
    }

    // MARK: - Output

    private static func emit(stage: String, band: String, samples: [Double]) {
        let distribution = LatencyDistributionReducer.reduce(samples)
        print("stage \(stage) \(band) count=\(distribution.count) median_s=\(format(distribution.median)) p95_s=\(format(distribution.p95)) p99_s=\(format(distribution.p99)) worst_s=\(format(distribution.worst))")
    }

    /// The plan's gates are p95, not median.
    private static func budget(_ name: String, target: Double, samples: [Double]) {
        let p95 = LatencyDistributionReducer.reduce(samples).p95
        print("budget \(name) target_p95_s=\(format(target)) p95_s=\(format(p95)) result=\(p95 <= target ? "pass" : "miss")")
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    private static func note(_ text: String) {
        FileHandle.standardError.write("\(text)\n".data(using: .utf8)!)
    }

    private static func runBlocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let box = BlockingBox<T>()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.result = .success(try await body()) } catch { box.result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try box.result!.get()
    }
}

private final class BlockingBox<T: Sendable>: @unchecked Sendable {
    var result: Result<T, Error>?
}

private struct ProfileFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
