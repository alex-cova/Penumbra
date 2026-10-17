import EditorIntelligence
import XCTest
@testable import JavaIntelligence

/// THROWAWAY false-positive sweep for `unresolved-member`. Not committed.
/// Run with UMBRA_JDK_HOME set to a JDK home containing lib/src.zip and lib/ct.sym.
final class ThrowawayUnresolvedMemberSweepTests: XCTestCase {
    func testSweep() async throws {
        guard let jdkHome = ProcessInfo.processInfo.environment["UMBRA_JDK_HOME"] else {
            throw XCTSkip("set UMBRA_JDK_HOME to run the sweep")
        }
        let jdk = JDKInstallation(
            home: URL(fileURLWithPath: jdkHome), featureVersion: 27, versionString: "27", vendor: nil
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: jdk.ctSym.path))
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sweep-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // JDK ct.sym shard (public surface only).
        let jdkShard = work.appendingPathComponent("jdk.idx")
        try JavaIndexShardWriter().write(
            try JDKCtSymRoot(installation: jdk).readStubs(),
            stamp: JavaStamp(size: 0, modificationDate: 0), to: jdkShard
        )

        // The java.base util/lang/io/net/time slice of src.zip, as real files.
        let sliceDir = work.appendingPathComponent("slice", isDirectory: true)
        let slicePrefixes = ["java.base/java/util/", "java.base/java/lang/", "java.base/java/io/",
                             "java.base/java/net/", "java.base/java/time/"]
        let sliceFiles = try unzip(zip: jdk.srcZip, prefixes: slicePrefixes, into: sliceDir)
        print("SWEEP slice files: \(sliceFiles.count)")

        // Index: JDK plus the slice's own source stubs (ct.sym drops the
        // private/package-private members the JDK's own code calls).
        var stubs: [JavaClassStub] = []
        for file in sliceFiles {
            let text = try String(contentsOf: file, encoding: .utf8)
            stubs.append(contentsOf: JavaSourceStubBuilder.build(source: text, url: file).classes)
        }
        let sliceShard = work.appendingPathComponent("slice.idx")
        try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: sliceShard)
        let index = JavaIndex()
        await index.setSources([
            .init(precedence: 1, reader: try JavaIndexShardReader(url: sliceShard)),
            .init(precedence: 3, reader: try JavaIndexShardReader(url: jdkShard)),
        ])

        var hits: [(String, String)] = []
        var skipped = 0
        for (number, file) in sliceFiles.enumerated() {
            if number % 200 == 0 { print("SWEEP slice progress \(number)/\(sliceFiles.count)") }
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            guard let tree = JavaSyntaxParser().parse(text),
                  let context = JavaInspectionContext(source: text, tree: tree, url: file, index: index) else {
                skipped += 1
                continue
            }
            let found = await JavaInspectionRunner.runTyped(context: context, enabled: [.unresolvedMember])
            for inspection in found {
                hits.append((file.lastPathComponent, "\(inspection.range.start.line + 1): \(inspection.message)"))
            }
        }
        print("SWEEP slice skipped(parse error): \(skipped)")
        print("SWEEP slice hits: \(hits.count)")
        for (file, message) in hits { print("SWEEP HIT \(file): \(message)") }

        // Gradle sources jars with only the JDK indexed: their own types are
        // unresolved, so the closed-hierarchy gate should keep this near-silent.
        let jarIndex = JavaIndex()
        await jarIndex.setSources([.init(precedence: 3, reader: try JavaIndexShardReader(url: jdkShard))])
        let jarPrefixes: [String] = []
        if let jars = ProcessInfo.processInfo.environment["UMBRA_SWEEP_JARS"] {
            for jar in jars.split(separator: ":").map(String.init) {
                let out = work.appendingPathComponent("jar-\(UUID().uuidString)", isDirectory: true)
                let files = try unzip(zip: URL(fileURLWithPath: jar), prefixes: jarPrefixes, into: out)
                    .filter { $0.pathExtension == "java" }.prefix(300)
                var jarHits = 0
                for file in files {
                    let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                    guard let tree = JavaSyntaxParser().parse(text),
                          let context = JavaInspectionContext(source: text, tree: tree, url: file, index: jarIndex) else { continue }
                    let found = await JavaInspectionRunner.runTyped(context: context, enabled: [.unresolvedMember])
                    jarHits += found.count
                    for inspection in found.prefix(20) {
                        print("SWEEP JARHIT \(file.lastPathComponent): \(inspection.message)")
                    }
                }
                print("SWEEP jar \(URL(fileURLWithPath: jar).lastPathComponent): \(files.count) files, \(jarHits) hits")
            }
        }

        // Repo fixtures smoke pass.
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Java/src")
        var fixtureHits = 0
        let fixtureFiles = javaFiles(at: fixtures)
        for file in fixtureFiles {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            guard let tree = JavaSyntaxParser().parse(text),
                  let context = JavaInspectionContext(source: text, tree: tree, url: file, index: jarIndex) else { continue }
            let found = await JavaInspectionRunner.runTyped(context: context, enabled: [.unresolvedMember])
            fixtureHits += found.count
            for inspection in found { print("SWEEP FIXTUREHIT \(file.lastPathComponent): \(inspection.message)") }
        }
        print("SWEEP fixtures: \(fixtureFiles.count) files, \(fixtureHits) hits")
    }

    private func javaFiles(at directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var result: [URL] = []
        for case let file as URL in enumerator where file.pathExtension == "java" { result.append(file) }
        return result.sorted { $0.path < $1.path }
    }

    /// Unzips `zip`, keeping entries under `prefixes` (empty = all), via the system unzip.
    private func unzip(zip: URL, prefixes: [String], into directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let list = try runUnzip(["-Z", "-1", zip.path])
        var kept: [String] = []
        for line in list.split(separator: "\n").map(String.init) {
            guard line.hasSuffix(".java"), prefixes.isEmpty || prefixes.contains(where: line.hasPrefix) else { continue }
            kept.append(line)
        }
        // Unzip in chunks to stay under the argument limit.
        for chunk in kept.chunked(into: 500) {
            _ = try runUnzip(["-q", "-o", zip.path] + chunk + ["-d", directory.path])
        }
        return kept.map { directory.appendingPathComponent($0) }.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }.sorted { $0.path < $1.path }
    }

    private func runUnzip(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
