import Foundation
import EditorIntelligence
import JavaIntelligence

/// Spike for docs/INTELLIJ_SMALLER_GAPS_PLAN.md item C (project-wide members in Go to Symbol):
/// how many members a real source tree has, what a flat member-name table costs in memory, and how
/// long a `CompletionMatcher` pass over it takes per keystroke.
///
///   swift run -c release PerfHarness java-members /path/to/java/sources
enum JavaMembersProfile {
    private struct Entry {
        let lower: String
        let name: String
        let owner: Int32
        let kind: UInt8
    }

    private static let queries = ["g", "get", "gN", "getN", "Name", "put", "lis", "nS", "toS", "x", "Id", "onC", "Str", "a"]

    static func run(root: String) {
        let directory = URL(fileURLWithPath: root)
        let parseStart = DispatchTime.now()
        let files = SourceRoot(directory: directory).readSourceFiles()
        let parseSeconds = seconds(since: parseStart)
        let classes = files.flatMap(\.classes)
        var methods = 0, constructors = 0, fields = 0, constants = 0
        for stub in classes {
            for method in stub.methods { if method.isConstructor { constructors += 1 } else { methods += 1 } }
            for field in stub.fields { if field.modifiers.contains(.enumConstant) { constants += 1 } else { fields += 1 } }
        }
        let total = methods + constructors + fields + constants
        print("files=\(files.count) classes=\(classes.count) methods=\(methods) constructors=\(constructors) fields=\(fields) enum_constants=\(constants) members=\(total)")
        print("parse_s=\(fmt(parseSeconds)) parse_files_per_s=\(Int(Double(files.count) / max(parseSeconds, 0.001)))")

        // What option 2 (a table built lazily from decoded stubs) pays before its first query.
        let shard = FileManager.default.temporaryDirectory.appendingPathComponent("members-spike-\(UUID().uuidString).idx")
        defer { try? FileManager.default.removeItem(at: shard) }
        do {
            var start = DispatchTime.now()
            try JavaIndexShardWriter().write(classes, stamp: JavaStamp(size: 0, modificationDate: 0), to: shard)
            let size = (try? shard.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            print("shard_write_s=\(fmt(seconds(since: start))) shard_mb=\(fmt(Double(size) / 1_048_576))")
            start = DispatchTime.now()
            let reader = try JavaIndexShardReader(url: shard)
            print("shard_open_s=\(fmt(seconds(since: start))) (header only: names and offsets)")
            start = DispatchTime.now()
            var decodedMembers = 0
            for name in reader.allQualifiedNames {
                if let stub = reader.classStub(named: name) { decodedMembers += stub.methods.count + stub.fields.count }
            }
            print("shard_decode_all_s=\(fmt(seconds(since: start))) decoded_members=\(decodedMembers)")
        } catch {
            print("shard measurement failed: \(error)")
        }

        let before = footprint()
        var owners: [String] = []
        var entries: [Entry] = []
        entries.reserveCapacity(total)
        for stub in classes {
            let owner = Int32(owners.count)
            owners.append(stub.qualifiedName)
            for method in stub.methods {
                entries.append(Entry(lower: method.name.lowercased(), name: method.name, owner: owner, kind: method.isConstructor ? 1 : 0))
            }
            for field in stub.fields {
                entries.append(Entry(lower: field.name.lowercased(), name: field.name, owner: owner, kind: 2))
            }
        }
        let after = footprint()
        // The parse results must outlive the second reading, or freeing them hides the table's cost.
        withExtendedLifetime((files, classes)) {}
        print("footprint_before=\(before) footprint_after=\(after)")
        let bytes = max(0, after - before)
        print("entry_stride_bytes=\(MemoryLayout<Entry>.stride) table_entries=\(entries.count) table_footprint_mb=\(fmt(Double(bytes) / 1_048_576)) bytes_per_entry=\(entries.isEmpty ? 0 : bytes / entries.count)")
        let longNames = entries.filter { $0.name.utf8.count > 15 }.count
        print("names_over_15_utf8_bytes=\(longNames) (\(entries.isEmpty ? 0 : longNames * 100 / entries.count)%: these allocate)")

        // Word-initial buckets: a query can only match at a word start, so it needs one bucket.
        let bucketBefore = footprint()
        var buckets = [[Int32]](repeating: [], count: 256)
        for (index, entry) in entries.enumerated() {
            var seen = Set<UInt8>()
            var previous: UInt8 = 0
            for (offset, byte) in entry.name.utf8.enumerated() {
                let isUpper = byte >= 65 && byte <= 90
                let previousIsLetter = (previous >= 65 && previous <= 90) || (previous >= 97 && previous <= 122)
                let isStart = offset == 0 || isUpper || !previousIsLetter
                if isStart {
                    let lower = isUpper ? byte + 32 : byte
                    if seen.insert(lower).inserted { buckets[Int(lower)].append(Int32(index)) }
                }
                previous = byte
            }
        }
        let bucketBytes = footprint() - bucketBefore
        let bucketEntries = buckets.reduce(0) { $0 + $1.count }
        print("bucket_entries=\(bucketEntries) (\(fmt(Double(bucketEntries) / Double(max(entries.count, 1)))) per member) bucket_mb=\(fmt(Double(bucketBytes) / 1_048_576)) largest_bucket=\(buckets.map(\.count).max() ?? 0)")

        // Scan latency: every query pass over the whole table, then the top 100 by match degree.
        for query in queries {
            let lowered = Array(query.lowercased().utf8)
            var plain: [Double] = []
            var filtered: [Double] = []
            var bucketed: [Double] = []
            var combined: [Double] = []
            var scanned = 0
            var hits = 0
            var survivors = 0
            for _ in 0..<15 {
                var start = DispatchTime.now()
                var found: [(Int, Int)] = []
                for (index, entry) in entries.enumerated() {
                    if let match = CompletionMatcher.match(query, in: entry.name) { found.append((match.degree, index)) }
                }
                found.sort { $0.0 > $1.0 }
                _ = found.prefix(100)
                plain.append(seconds(since: start))
                hits = found.count

                start = DispatchTime.now()
                var quick: [(Int, Int)] = []
                var passed = 0
                for (index, entry) in entries.enumerated() where isSubsequence(lowered, of: entry.lower) {
                    passed += 1
                    if let match = CompletionMatcher.match(query, in: entry.name) { quick.append((match.degree, index)) }
                }
                quick.sort { $0.0 > $1.0 }
                _ = quick.prefix(100)
                filtered.append(seconds(since: start))
                survivors = passed
                precondition(quick.count == found.count, "the subsequence pre-check must never drop a match")

                start = DispatchTime.now()
                var fromBucket: [(Int, Int)] = []
                let bucket = buckets[Int(lowered[0])]
                for index in bucket {
                    let entry = entries[Int(index)]
                    if let match = CompletionMatcher.match(query, in: entry.name) { fromBucket.append((match.degree, Int(index))) }
                }
                fromBucket.sort { $0.0 > $1.0 }
                _ = fromBucket.prefix(100)
                bucketed.append(seconds(since: start))
                scanned = bucket.count

                // Bucket, then the subsequence pre-check, then the matcher, keeping a running top 100
                // instead of sorting every hit.
                start = DispatchTime.now()
                var top: [(Int, Int)] = []
                var floor = Int.min
                var total = 0
                for index in bucket {
                    let entry = entries[Int(index)]
                    guard isSubsequence(lowered, of: entry.lower) else { continue }
                    guard let match = CompletionMatcher.match(query, in: entry.name) else { continue }
                    total += 1
                    if match.degree > floor || top.count < 100 {
                        top.append((match.degree, Int(index)))
                        if top.count >= 200 {
                            top.sort { $0.0 > $1.0 }
                            top.removeLast(top.count - 100)
                            floor = top[99].0
                        }
                    }
                }
                top.sort { $0.0 > $1.0 }
                combined.append(seconds(since: start))
                precondition(total == found.count, "combined path dropped a match")
                precondition(fromBucket.count == found.count, "the word-initial bucket must never drop a match: \(query) \(fromBucket.count) vs \(found.count)")
            }
            let p = LatencyDistributionReducer.reduce(plain)
            let f = LatencyDistributionReducer.reduce(filtered)
            let b = LatencyDistributionReducer.reduce(bucketed)
            let c = LatencyDistributionReducer.reduce(combined)
            print("query=\(query) bucket_scanned=\(scanned) bucketed_median_ms=\(fmt(b.median * 1000)) bucketed_p95_ms=\(fmt(b.p95 * 1000)) combined_median_ms=\(fmt(c.median * 1000)) combined_p95_ms=\(fmt(c.p95 * 1000))")
            print("query=\(query) hits=\(hits) survivors=\(survivors) plain_median_ms=\(fmt(p.median * 1000)) plain_p95_ms=\(fmt(p.p95 * 1000)) prefiltered_median_ms=\(fmt(f.median * 1000)) prefiltered_p95_ms=\(fmt(f.p95 * 1000))")
        }
        _ = owners
        measureShippedIndex(classes)
    }

    /// The real thing: `JavaIndex.members` over a shard of these classes, including the first call
    /// that builds the table, and a warm run with an open buffer overriding one class.
    private static func measureShippedIndex(_ classes: [JavaClassStub]) {
        let shard = FileManager.default.temporaryDirectory.appendingPathComponent("members-index-\(UUID().uuidString).idx")
        defer { try? FileManager.default.removeItem(at: shard) }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                try JavaIndexShardWriter().write(classes, stamp: JavaStamp(size: 0, modificationDate: 0), to: shard)
                let index = JavaIndex()
                await index.setSources([.init(precedence: 1, reader: try JavaIndexShardReader(url: shard))])
                var start = DispatchTime.now()
                let first = await index.members(matching: "getN", limit: 100)
                print("index_first_query_s=\(fmt(seconds(since: start))) (builds the member table) hits=\(first.count)")
                if let stub = classes.first {
                    await index.replaceOverlay(removing: [], adding: [stub])
                }
                for query in queries {
                    var samples: [Double] = []
                    var count = 0
                    for _ in 0..<15 {
                        start = DispatchTime.now()
                        count = await index.members(matching: query, limit: 100).count
                        samples.append(seconds(since: start))
                    }
                    let d = LatencyDistributionReducer.reduce(samples)
                    print("index_query=\(query) results=\(count) median_ms=\(fmt(d.median * 1000)) p95_ms=\(fmt(d.p95 * 1000))")
                }
            } catch {
                print("index measurement failed: \(error)")
            }
            done.signal()
        }
        done.wait()
    }

    /// Every character of `query` appears in `name` in order, ignoring case. All match tiers imply it.
    private static func isSubsequence(_ query: [UInt8], of name: String) -> Bool {
        var index = 0
        for byte in name.utf8 {
            if index < query.count, byte == query[index] { index += 1 }
        }
        return index == query.count
    }

    private static func seconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }

    private static func fmt(_ value: Double) -> String { String(format: "%.3f", value) }

    /// Bytes in use on the malloc heap: unlike the physical footprint it does not move when
    /// unrelated temporaries are freed.
    private static func footprint() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return stats.size_in_use
    }
}
