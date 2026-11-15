import Foundation
import EditorIntelligence
import JavaIntelligence

/// What the host's re-check triggers cost: the exact `JavaInspectionService` calls Umbra made
/// before this change and the calls it makes now, replayed against the same open files and the
/// installed JDK's index. Counts passes that published (the service's result handler) and wall
/// time until every file is current again.
///
///   swift run -c release PerfHarness java-reinspection synthetic --files 5 --lines 2000
///
/// Scenarios (each starts from every file current):
/// - `compiler_refresh`: a sync or JDK refresh that leaves the language levels as they were.
///   Before: `setLanguageLevelResolver` without an identity (clears every result), then
///   `compileNow`'s `analyzeNow` per file. Now: the same resolver with its identity (a no-op).
/// - `jdk_switch`: a JDK replacement. Before: the publish's re-check plus a forced re-analysis
///   per file. Now: the publish's re-check only.
/// - `identical_republish`: the same readers and flag published again (a model removal, a folder
///   re-open with nothing new). Before: a version bump and a re-check of every file (reproduced
///   by publishing fresh readers of the same shard). Now: a no-op.
/// - `reread_republish`: fresh readers of unchanged shards (what a save's stub refresh publishes
///   today). Still re-checks every file; measured, not fixed.
enum JavaReinspectionProfile {
    static func run(files: Int, lines: Int) throws {
        try runBlocking { try await measure(files: files, lines: lines) }
    }

    private static func measure(files count: Int, lines: Int) async throws {
        guard let jdk = JDKLocator().select() else {
            throw ReinspectionFailure(message: "java-reinspection needs an installed JDK")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("perf-reinspect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (root, _) = JDKIndexRoot.make(for: jdk)
        let shard = directory.appendingPathComponent("jdk.idx")
        try JavaIndexShardWriter().write(try root.readStubs(), stamp: JavaStamp(size: 0, modificationDate: 0), to: shard)

        let source = JavaInspectionsProfile.syntheticJava(lines: lines)
        let documents = (0..<count).map { number in
            document(url: URL(fileURLWithPath: "/perf/File\(number).java"), text: source.replacingOccurrences(of: "Service", with: "Service\(number)x"))
        }

        func freshIndex() async throws -> (JavaIndex, JavaIndex.Source) {
            let index = JavaIndex()
            let source = JavaIndex.Source(precedence: 3, reader: try JavaIndexShardReader(url: shard))
            await index.setSources([source])
            return (index, source)
        }

        let resolver: @Sendable (URL) -> Int? = { _ in jdk.featureVersion }

        // compiler_refresh
        try await scenario("compiler_refresh", documents: documents, setup: freshIndex) { service, _, _, old in
            if old {
                await service.setLanguageLevelResolver(resolver)
            } else {
                await service.setLanguageLevelResolver(resolver, identity: "\(jdk.featureVersion)|")
            }
            for document in documents { await service.analyzeNow(document) }
        } prepare: { service in
            await service.setLanguageLevelResolver(resolver, identity: "\(jdk.featureVersion)|")
        }

        // jdk_switch (a replacement reader of the same JDK stands in for the new JDK)
        try await scenario("jdk_switch", documents: documents, setup: freshIndex) { service, index, _, old in
            await index.setSources([.init(precedence: 3, reader: try! JavaIndexShardReader(url: shard))])
            await service.refreshAfterIndexChange(documents)
            if old {
                for document in documents { await service.analyzeNow(document, force: true) }
            }
        }

        // identical_republish
        try await scenario("identical_republish", documents: documents, setup: freshIndex) { service, index, source, old in
            let republished = old ? JavaIndex.Source(precedence: 3, reader: try! JavaIndexShardReader(url: shard)) : source
            await index.setSources([republished])
            await service.refreshAfterIndexChange(documents)
        }

        // reread_republish (what remains)
        try await scenario("reread_republish", documents: documents, setup: freshIndex, onlyNow: true) { service, index, _, _ in
            await index.setSources([.init(precedence: 3, reader: try! JavaIndexShardReader(url: shard))])
            await service.refreshAfterIndexChange(documents)
        }
    }

    private static func scenario(
        _ name: String,
        documents: [Document],
        setup: () async throws -> (JavaIndex, JavaIndex.Source),
        onlyNow: Bool = false,
        trigger: @escaping (JavaInspectionService, JavaIndex, JavaIndex.Source, Bool) async -> Void,
        prepare: ((JavaInspectionService) async -> Void)? = nil
    ) async throws {
        for old in onlyNow ? [false] : [true, false] {
            let (index, source) = try await setup()
            let service = JavaInspectionService(index: index, idleDelay: .zero)
            if let prepare { await prepare(service) }
            let counter = PublishCounter()
            for document in documents { await service.analyzeNow(document) }
            await service.setResultHandler { _, _ in counter.increment() }
            let start = DispatchTime.now().uptimeNanoseconds
            await trigger(service, index, source, old)
            // Until every file is current again (scheduled passes included).
            while true {
                var allFresh = true
                for document in documents where !(await service.isFresh(document)) { allFresh = false }
                if allFresh { break }
                for document in documents { await service.analyzeNow(document) }
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            print("stage java_reinspection scenario=\(name) variant=\(old ? "before" : "after") files=\(documents.count) passes=\(counter.value) wall_s=\(String(format: "%.4f", elapsed))")
        }
    }

    private static func document(url: URL, text: String) -> Document {
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        return Document(
            url: url, displayName: url.lastPathComponent, contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: TextRange(start: position, end: position)), cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100), languageIdentifier: "java"
        )
    }

    private static func runBlocking(_ body: @escaping @Sendable () async throws -> Void) throws {
        let box = ReinspectionBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do { try await body() } catch { box.error = error }
            semaphore.signal()
        }
        semaphore.wait()
        if let error = box.error { throw error }
    }
}

private final class PublishCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class ReinspectionBox: @unchecked Sendable {
    var error: Error?
}

private struct ReinspectionFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
