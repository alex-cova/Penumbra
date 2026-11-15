import Foundation
import JavaIntelligence

/// What release-aware platforms cost (`Sources/JavaIntelligence/Platform/`), on the selected JDK:
///
///   swift run -c release PerfHarness java-platform-release synthetic [--releases 8,11,17]
///
/// - `cold`: reading one release's signatures from `ct.sym` and writing its shard (what the first
///   module on `--release N` waits for, once per JDK and release for the whole app).
/// - `warm`: the same request through `JavaSharedShardHub` once the shard exists (a second
///   window, a re-sync, a relaunch with the shard on disk), and once the reader is cached.
/// - `memory`: resident growth for loading each release's reader, with its class count and shard size.
/// - `set_sources`: publishing one platform versus the default plus every release.
/// - `lookup`: `classStub` + `classes(simpleNamePrefix:)` under a release scope versus unscoped, the
///   per-query cost of choosing among several platforms.
enum JavaPlatformReleaseProfile {
    static func run(releases: [Int]) throws {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failure: Error?
        Task.detached {
            do { try await measure(releases: releases) } catch { failure = error }
            semaphore.signal()
        }
        semaphore.wait()
        if let failure { throw failure }
    }

    private static func measure(releases wanted: [Int]) async throws {
        guard let jdk = JDKLocator().select() else { throw Failure("java-platform-release needs an installed JDK") }
        let supported = JDKPlatformRoot.supportedReleases(of: jdk)
        let releases = wanted.filter { $0 != jdk.featureVersion && supported.contains($0) }
        print("=== java platform release profile (\(jdk.displayName), releases \(releases), ct.sym has \(supported.sorted())) ===")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("perf-platform-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = JavaIndexPaths(root: directory)

        // Default platform.
        var started = now()
        let (ownRoot, ownKind) = JDKIndexRoot.make(for: jdk)
        let hub = JavaSharedShardHub(paths: paths)
        guard let own = await hub.shard(for: ownRoot, at: paths.jdkShard(jdk, kind: ownKind)) else { throw Failure("default platform did not index") }
        print("stage default_cold_s=\(format(now() - started)) kind=\(ownKind) classes=\(own.allQualifiedNames.count)")

        var readers: [Int: JavaIndexShardReader] = [:]
        for release in releases {
            guard let made = JDKPlatformRoot.make(for: jdk, release: release) else { continue }
            let shardURL = paths.jdkShard(jdk, kind: made.kind)
            started = now()
            let rssBefore = Measurement.residentMemoryBytes()
            guard let reader = await hub.shard(for: made.root, at: shardURL) else { throw Failure("release \(release) did not index") }
            let cold = now() - started
            let rssAfter = Measurement.residentMemoryBytes()
            started = now()
            _ = await hub.shard(for: made.root, at: shardURL)
            let cached = now() - started
            // A fresh hub: the shard is on disk (a relaunch, another process).
            let fresh = JavaSharedShardHub(paths: paths)
            started = now()
            let rssFreshBefore = Measurement.residentMemoryBytes()
            let reread = await fresh.shard(for: made.root, at: shardURL)
            let fromDisk = now() - started
            let rssFreshAfter = Measurement.residentMemoryBytes()
            let size = (try? FileManager.default.attributesOfItem(atPath: shardURL.path)[.size] as? Int) ?? 0
            print("stage release=\(release) cold_s=\(format(cold)) warm_disk_s=\(format(fromDisk)) warm_cached_s=\(format(cached)) "
                  + "classes=\(reader.allQualifiedNames.count) shard_mb=\(format(Double(size) / 1_048_576)) "
                  + "rss_cold_mb=\(format(Double(Int64(rssAfter) - Int64(rssBefore)) / 1_048_576)) "
                  + "rss_reader_mb=\(format(Double(Int64(rssFreshAfter) - Int64(rssFreshBefore)) / 1_048_576)) reread=\(reread != nil)")
            readers[release] = reader
        }

        // Publishing.
        let ownToken = JavaPlatformScope.token(release: jdk.featureVersion)
        let single: [JavaIndex.Source] = [.init(precedence: 3, reader: own, shardPath: ownToken, isDefaultPlatform: true)]
        let all = single + readers.sorted { $0.key < $1.key }.map {
            JavaIndex.Source(precedence: 3, reader: $0.value, shardPath: JavaPlatformScope.token(release: $0.key))
        }
        let singleIndex = JavaIndex()
        started = now()
        await singleIndex.setSources(single)
        let singleSet = now() - started
        let multiIndex = JavaIndex()
        started = now()
        await multiIndex.setSources(all)
        print("stage set_sources_single_s=\(format(singleSet)) set_sources_all_s=\(format(now() - started)) platforms=\(all.count)")

        // Per-query cost.
        let names = ["java.util.List", "java.lang.String", "java.util.concurrent.ConcurrentHashMap", "java.nio.ByteBuffer", "java.time.LocalDate"]
        func lookups(_ index: JavaIndex, scope: Set<String>?) async -> [Double] {
            var samples: [Double] = []
            for round in 0..<30 {
                let start = now()
                await JavaIndex.$queryScope.withValue(scope) {
                    for name in names { _ = await index.classStub(qualifiedName: name) }
                    _ = await index.classes(simpleNamePrefix: "Str")
                    _ = await index.classes(simpleNamePrefix: "Li")
                    _ = await index.classes(simpleName: "List")
                }
                if round >= 5 { samples.append(now() - start) }
            }
            return samples.sorted()
        }
        let base = await lookups(singleIndex, scope: nil)
        print("stage lookup_single_unscoped median_ms=\(format(median(base) * 1000)) p95_ms=\(format(p95(base) * 1000))")
        let multiDefault = await lookups(multiIndex, scope: nil)
        print("stage lookup_multi_unscoped median_ms=\(format(median(multiDefault) * 1000)) p95_ms=\(format(p95(multiDefault) * 1000))")
        for release in readers.keys.sorted() {
            let scoped = await lookups(multiIndex, scope: [JavaPlatformScope.token(release: release)])
            print("stage lookup_multi_release\(release) median_ms=\(format(median(scoped) * 1000)) p95_ms=\(format(p95(scoped) * 1000))")
        }
    }

    private static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
    private static func median(_ values: [Double]) -> Double { values.isEmpty ? 0 : values[values.count / 2] }
    private static func p95(_ values: [Double]) -> Double { values.isEmpty ? 0 : values[min(values.count - 1, values.count * 95 / 100)] }
    private static func format(_ value: Double) -> String { String(format: "%.3f", value) }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
