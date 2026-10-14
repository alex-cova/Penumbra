import Foundation
import JavaIntelligence

/// Release-mode cost of reading a Flight Recorder text dump into a profile, and of turning a JaCoCo
/// report of a big file into editor bands. Neither runs on a keystroke; what matters is that the
/// import is linear in the dump and its memory follows the distinct stacks, not the samples.
///
///   swift run -c release PerfHarness java-profile-import synthetic --samples 60000 --depth 128
///   swift run -c release PerfHarness java-coverage-bands synthetic --lines 20000
enum JavaInstrumentationProfile {
    // MARK: - Profile import

    static func runProfileImport(samples: Int, depth: Int, stacks: Int) {
        let text = syntheticDump(samples: samples, depth: depth, stacks: stacks)
        let megabytes = Double(text.utf8.count) / 1_048_576
        var parser = JFRTextParser()
        var profile = JavaProfile(symbols: parser.symbols)
        let start = DispatchTime.now().uptimeNanoseconds
        // Fed in 64 KB pieces, the way a pipe delivers it.
        let bytes = Array(text.utf8)
        var index = 0
        while index < bytes.count {
            let end = min(bytes.count, index + 65_536)
            parser.feed(Data(bytes[index..<end])) { profile.ingest($0) }
            index = end
        }
        parser.finish { profile.ingest($0) }
        let imported = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9

        let hotStart = DispatchTime.now().uptimeNanoseconds
        let hot = profile.cpu.hotMethods(symbols: profile.symbols, limit: 50)
        let hotSeconds = Double(DispatchTime.now().uptimeNanoseconds - hotStart) / 1e9

        let foldStart = DispatchTime.now().uptimeNanoseconds
        let folded = profile.cpu.foldedStacks(symbols: profile.symbols).count
        let foldSeconds = Double(DispatchTime.now().uptimeNanoseconds - foldStart) / 1e9

        // What the tab does as the user drags a range, picks a thread, opens the timeline, the line
        // hints and a comparison: each is a pass over the sample table or the tree, never a re-read.
        func timed<T>(_ body: () -> T) -> (T, Double) {
            let begin = DispatchTime.now().uptimeNanoseconds
            let value = body()
            return (value, Double(DispatchTime.now().uptimeNanoseconds - begin) / 1e9)
        }
        var queryResult = 0
        if let span = profile.timeSpan {
            let length = span.upperBound - span.lowerBound
            let (_, rangeSeconds) = timed {
                for step in 0 ..< 20 {
                    let low = span.lowerBound + Int32(step) * length / 40
                    queryResult &+= profile.tree(of: .cpu, thread: nil, range: low...(low + length / 10)).totalSamples
                }
            }
            let (_, threadSeconds) = timed {
                for thread in 0 ..< 4 {
                    queryResult &+= profile.tree(of: .cpu, thread: "worker-\(thread)", range: nil).totalSamples
                }
            }
            let (timeline, timelineSeconds) = timed { JavaProfileTimeline.build(from: profile) }
            print("stage profile_range_query queries=20 rows=\(profile.cpuSamplesTable.count) seconds_per_query=\(format(rangeSeconds / 20)) "
                + "thread_seconds_per_query=\(format(threadSeconds / 4)) checksum=\(queryResult)")
            print("stage profile_timeline lanes=\(timeline?.lanes.count ?? 0) buckets=\(timeline?.bucketCount ?? 0) seconds=\(format(timelineSeconds))")
        }
        let (lineProfile, lineSeconds) = timed { JavaLineProfile.build(from: profile.cpu, symbols: profile.symbols) }
        print("stage profile_line_costs classes=\(lineProfile.classNames.count) seconds=\(format(lineSeconds))")
        let (comparison, compareSeconds) = timed {
            JavaProfileComparison.compare(
                baseline: profile.cpu, baselineSymbols: profile.symbols, target: profile.cpu, targetSymbols: profile.symbols
            )
        }
        print("stage profile_compare nodes=\(comparison.tree.nodeCount) methods=\(comparison.rows.count) seconds=\(format(compareSeconds))")
        let (collapsed, collapseSeconds) = timed { profile.cpu.collapsingRecursion(symbols: profile.symbols) }
        print("stage profile_collapse_recursion nodes=\(collapsed.nodeCount) seconds=\(format(collapseSeconds))")

        print("stage profile_import samples=\(profile.cpuSamples) dump_mb=\(format(megabytes)) seconds=\(format(imported)) "
            + "mb_per_s=\(format(megabytes / max(imported, 1e-9))) nodes=\(profile.cpu.nodeCount) "
            + "frames=\(profile.symbols.frames.count) folded_samples=\(profile.cpu.foldedSamples)")
        print("stage profile_hot_methods count=\(hot.count) seconds=\(format(hotSeconds))")
        print("stage profile_folded_stacks lines=\(folded) seconds=\(format(foldSeconds))")
    }

    /// A recursive workload sampled on four threads: `stacks` distinct call paths, each between 1
    /// and `depth` frames deep, repeated to `samples` events.
    static func syntheticDump(samples: Int, depth: Int, stacks: Int) -> String {
        var variants: [String] = []
        variants.reserveCapacity(stacks)
        for variant in 0 ..< stacks {
            let length = 1 + (variant * 7919) % depth
            var block = ""
            for level in 0 ..< length {
                block += "    com.acme.work.Recursive\(variant % 40).step(int) line: \(level % 90)\n"
            }
            block += "    com.acme.work.Main.run() line: 12\n"
            block += "    java.lang.Thread.run() line: 1516\n"
            variants.append(block)
        }
        var out = ""
        out.reserveCapacity(samples * 400)
        for sample in 0 ..< samples {
            out += "jdk.ExecutionSample {\n"
            // 10 ms apart, so a recording of 60 000 samples is ten minutes.
            let millis = sample * 10
            out += String(
                format: "  startTime = %02d:%02d:%02d.%03d (2026-10-13)\n",
                12 + millis / 3_600_000, (millis / 60_000) % 60, (millis / 1000) % 60, millis % 1000
            )
            out += "  sampledThread = \"worker-\(sample % 4)\" (javaThreadId = \(40 + sample % 4))\n"
            out += "  state = \"STATE_RUNNABLE\"\n"
            out += "  stackTrace = [\n"
            out += variants[(sample &* 2_654_435_761) % stacks]
            out += "  ]\n}\n\n"
        }
        return out
    }

    // MARK: - Coverage bands

    static func runCoverageBands(lines: Int) throws {
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><!DOCTYPE report PUBLIC "-//JACOCO//DTD Report 1.1//EN" "report.dtd">
        <report name="perf"><package name="perf"><sourcefile name="Big.java">
        """
        // Alternating covered and missed lines: the worst case for merging, one band per line.
        for line in 1 ... lines {
            if line % 2 == 0 {
                xml += "<line nr=\"\(line)\" mi=\"0\" ci=\"3\" mb=\"0\" cb=\"0\"/>"
            } else {
                xml += "<line nr=\"\(line)\" mi=\"4\" ci=\"0\" mb=\"0\" cb=\"0\"/>"
            }
        }
        xml += "<counter type=\"LINE\" missed=\"\(lines / 2)\" covered=\"\(lines / 2)\"/></sourcefile></package></report>"
        let data = Data(xml.utf8)

        let parseStart = DispatchTime.now().uptimeNanoseconds
        let report = try JaCoCoXMLReportParser.parse(data) { _ in URL(fileURLWithPath: "/perf/Big.java") }
        let parseSeconds = Double(DispatchTime.now().uptimeNanoseconds - parseStart) / 1e9

        let file = try require(report.sourceFiles.first)
        let bandsStart = DispatchTime.now().uptimeNanoseconds
        let bands = file.bands
        let bandsSeconds = Double(DispatchTime.now().uptimeNanoseconds - bandsStart) / 1e9

        // The lookup a gutter or a navigation key does, 100 000 of them.
        let lookupStart = DispatchTime.now().uptimeNanoseconds
        var hits = 0
        for index in 0 ..< 100_000 where file.status(atLine: 1 + (index * 31) % lines) != nil { hits += 1 }
        let lookupSeconds = Double(DispatchTime.now().uptimeNanoseconds - lookupStart) / 1e9

        print("stage coverage_parse lines=\(lines) xml_kb=\(data.count / 1024) seconds=\(format(parseSeconds))")
        print("stage coverage_bands bands=\(bands.count) seconds=\(format(bandsSeconds))")
        print("stage coverage_status_lookup lookups=100000 hits=\(hits) seconds=\(format(lookupSeconds))")
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw NSError(domain: "PerfHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: "empty report"]) }
        return value
    }

    private static func format(_ value: Double) -> String { String(format: "%.4f", value) }
}
