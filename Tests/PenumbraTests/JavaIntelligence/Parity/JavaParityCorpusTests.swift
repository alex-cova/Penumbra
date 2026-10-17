import EditorIntelligence
import Foundation
import XCTest
@testable import JavaIntelligence

/// The parity scorecard (§2 of the java-intelligence-parity plan): mutated valid sources,
/// labelled by the oracle, measured against the native checks.
///
/// Runs only with `JAVA_PARITY=1` (and a JDK with `ct.sym`); skipped otherwise. Failures are
/// always actionable: an oracle key mismatch prints the oracle's actual keys (a mis-remembered
/// key corrects itself), and a metric regression prints the baseline delta. PR2 covers errors
/// only, with `unresolved-member` and `unresolved-type` as the native side; type agreement,
/// latency gates and the refactoring compile rate arrive with their phases.
///
/// `UPDATE_JAVA_PARITY_BASELINE=1` rewrites `Fixtures/JavaParityCorpus/baseline.json` and
/// regenerates `docs/JAVA_PARITY.md` from it. `JAVA_PARITY_CASE=Prefix` runs a subset (no
/// ratchet comparison then, like the completion corpus).
final class JavaParityCorpusTests: XCTestCase {
    // MARK: - Baseline

    struct KeyMetrics: Codable {
        var oracle: Int
        var oracleMatched: Int
        var native: Int
        var nativeMatched: Int

        var recall: Double { oracle == 0 ? 1 : Double(oracleMatched) / Double(oracle) }
        var precision: Double? { native == 0 ? nil : Double(nativeMatched) / Double(native) }
    }

    struct Baseline: Codable {
        var jdkVersion: Int
        var keys: [String: KeyMetrics]
        var validFalsePositives: Int
        var mutations: [String]

        static var url: URL {
            // #filePath is Tests/PenumbraTests/JavaIntelligence/Parity/<file>; three levels up
            // is Tests/PenumbraTests, which holds Fixtures/.
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/JavaParityCorpus/baseline.json")
        }

        static func load() -> Baseline? {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(Baseline.self, from: data)
        }

        func save() throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(self).write(to: Self.url)
        }
    }

    // MARK: - Run

    private struct OracleError {
        let key: String
        let line: Int
    }

    private struct NativeFinding {
        let rule: String
        let line: Int
        let severity: JavaInspection.Severity
    }

    private struct MutationResult {
        let mutation: JavaParityMutator.Mutation
        let oracle: [OracleError]
        var native: [NativeFinding]
        let seconds: Double
        var keyMismatch: String?
    }

    func testParityScorecard() async throws {
        guard ProcessInfo.processInfo.environment["JAVA_PARITY"] == "1" else {
            throw XCTSkip("Parity corpus runs only with JAVA_PARITY=1")
        }
        let environment = try ParityTestSupport.requireEnvironment()
        let client = ParityTestSupport.makeClient(jarURL: environment.jarURL, jdk: environment.jdk)
        defer { Task { await client.shutdown() } }

        let valid = try loadValidFixtures()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("java-parity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var validURLs: [String: URL] = [:]
        for (name, text) in valid {
            let url = root.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            validURLs[name] = url
        }

        var mutations = JavaParityMutator.all()
        let only = ProcessInfo.processInfo.environment["JAVA_PARITY_CASE"]
        if let only {
            mutations = mutations.filter { $0.id.hasPrefix(only) }
            XCTAssertFalse(mutations.isEmpty, "no mutation matches JAVA_PARITY_CASE=\(only)")
        }

        // The oracle labels every mutation; the mutated file is checked from memory while its
        // valid siblings resolve from disk.
        try await client.configure(JavaAnalysisServerModule(moduleId: "parity", sourcepath: [root]))
        for (name, text) in valid {
            let errors = try await oracleErrors(client: client, file: validURLs[name]!, text: text)
            XCTAssertTrue(errors.isEmpty, "\(name) is not oracle-clean: \(errors)")
        }
        var results: [MutationResult] = []
        for mutation in mutations {
            let base = try XCTUnwrap(valid[mutation.fixture], "\(mutation.fixture) missing")
            guard let mutated = JavaParityMutator.apply(mutation, to: base) else {
                XCTFail("\(mutation.id): anchor missing in \(mutation.fixture)")
                continue
            }
            let start = Date()
            let oracle = try await oracleErrors(client: client, file: validURLs[mutation.fixture]!, text: mutated)
            let seconds = Date().timeIntervalSince(start)
            var result = MutationResult(mutation: mutation, oracle: oracle, native: [], seconds: seconds)
            let actual = oracle.map(\.key).sorted()
            let expected = mutation.expectedKeys.sorted()
            if actual.count != expected.count || zip(actual, expected).contains(where: { !$0.hasPrefix($1) }) {
                result.keyMismatch = "oracle reports \(actual), expected \(expected)"
            }
            results.append(result)
        }

        // The native side: unresolved-member plus unresolved-type over a JDK + fixtures index.
        let index = try await buildIndex(valid: valid, root: root, jdk: environment.jdk)
        var validFindings: [NativeFinding] = []
        for (name, text) in valid {
            validFindings += await nativeFindings(text: text, url: validURLs[name]!, index: index)
        }
        for position in results.indices {
            let mutation = results[position].mutation
            let base = valid[mutation.fixture]!
            let mutated = JavaParityMutator.apply(mutation, to: base)!
            results[position].native = await nativeFindings(text: mutated, url: validURLs[mutation.fixture]!, index: index)
        }

        let report = Scorecard(results: results, validFindings: validFindings, jdkVersion: environment.jdk.featureVersion)
        print(report.render(baseline: Baseline.load()))
        try? report.render(baseline: Baseline.load()).write(
            to: FileManager.default.temporaryDirectory.appendingPathComponent("java-parity-scorecard.txt"),
            atomically: true, encoding: .utf8
        )

        for result in results {
            if let mismatch = result.keyMismatch { XCTFail("\(result.mutation.id): \(mismatch)") }
        }

        if only != nil { return }
        if ProcessInfo.processInfo.environment["UPDATE_JAVA_PARITY_BASELINE"] == "1" {
            try report.baseline().save()
            try Self.regenerateParityDoc(report: report)
            return
        }
        guard let baseline = Baseline.load() else {
            print("NEW BASELINE NEEDED: run with UPDATE_JAVA_PARITY_BASELINE=1 to write it")
            return
        }
        for failure in report.ratchetFailures(baseline: baseline) { XCTFail(failure) }
    }

    // MARK: - Oracle and native runs

    private func loadValidFixtures() throws -> [String: String] {
        let directory = try ParityTestSupport.fixtureDirectory("valid")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "java" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(files.isEmpty, "no valid fixtures in \(directory)")
        var result: [String: String] = [:]
        for file in files {
            result[file.lastPathComponent] = try String(contentsOf: file, encoding: .utf8)
        }
        return result
    }

    private func oracleErrors(client: JavaAnalysisServerClient, file: URL, text: String) async throws -> [OracleError] {
        let lines = LineTable(text)
        return try await client.check(moduleId: "parity", file: file, text: text)
            .filter { $0.severity == .error && $0.file == file.path }
            .map { diagnostic in
                let line = diagnostic.line
                    ?? diagnostic.start.map { lines.position(atOffset: $0).line + 1 }
                    ?? 0
                return OracleError(key: diagnostic.key, line: line)
            }
            .sorted { ($0.line, $0.key) < ($1.line, $1.key) }
    }

    private func nativeFindings(text: String, url: URL, index: JavaIndex) async -> [NativeFinding] {
        guard let tree = JavaSyntaxParser().parse(text) else { return [] }
        let inspections = await JavaInspectionPipeline.inspect(
            text: text, url: url, tree: tree, index: index,
            enabled: [.unresolvedMember, .unresolvedType], thresholds: .standard
        )
        return inspections
            .filter { $0.id == "unresolved-member" || $0.id == "unresolved-type" }
            .map { NativeFinding(rule: $0.id, line: $0.range.start.line + 1, severity: $0.severity) }
    }

    private func buildIndex(valid: [String: String], root: URL, jdk: JDKInstallation) async throws -> JavaIndex {
        let temporary = FileManager.default.temporaryDirectory
        let jdkShard = temporary.appendingPathComponent("parity-jdk-\(UUID().uuidString).idx")
        try JavaIndexShardWriter().write(
            try JDKCtSymRoot(installation: jdk).readStubs(),
            stamp: JavaStamp(size: 0, modificationDate: 0), to: jdkShard)
        var projectStubs: [JavaClassStub] = []
        for (name, text) in valid {
            projectStubs += JavaSourceStubBuilder.build(source: text, url: root.appendingPathComponent(name)).classes
        }
        let projectShard = temporary.appendingPathComponent("parity-project-\(UUID().uuidString).idx")
        try JavaIndexShardWriter().write(projectStubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: projectShard)
        let index = JavaIndex()
        await index.setSources([
            .init(precedence: 1, reader: try JavaIndexShardReader(url: projectShard)),
            .init(precedence: 3, reader: try JavaIndexShardReader(url: jdkShard)),
        ])
        return index
    }

    // MARK: - Scorecard and doc

    private struct Scorecard {
        let results: [MutationResult]
        let validFindings: [NativeFinding]
        let jdkVersion: Int

        /// Native rule ids that read as this javac key group; `nil` means no native rule yet.
        static func group(forKey key: String) -> String? {
            key.hasPrefix("compiler.err.cant.resolve") ? "cant.resolve*" : nil
        }

        static func group(forRule rule: String) -> String? {
            (rule == "unresolved-member" || rule == "unresolved-type") ? "cant.resolve*" : nil
        }

        func metrics() -> [String: KeyMetrics] {
            var oracleByKey: [String: [OracleError]] = [:]
            for result in results {
                for error in result.oracle { oracleByKey[error.key, default: []].append(error) }
            }
            var metrics: [String: KeyMetrics] = [:]
            for (key, errors) in oracleByKey {
                let group = Self.group(forKey: key)
                let matched = errors.filter { error in
                    results.contains { result in
                        result.oracle.contains { $0.key == error.key && $0.line == error.line }
                            && result.native.contains { Self.group(forRule: $0.rule) == group && $0.line == error.line }
                    }
                }.count
                // Precision counts are per group and filled in below; recall is per key.
                metrics[key] = KeyMetrics(oracle: errors.count, oracleMatched: matched, native: 0, nativeMatched: 0)
            }
            // Precision is per group: every native finding in the group is matched against the
            // group's oracle errors on the same line, then shared by the group's keys.
            var groupNative: [String: Int] = [:]
            var groupNativeMatched: [String: Int] = [:]
            for result in results {
                for finding in result.native {
                    guard let group = Self.group(forRule: finding.rule) else { continue }
                    groupNative[group, default: 0] += 1
                    let hit = result.oracle.contains { error in
                        Self.group(forKey: error.key) == group && error.line == finding.line
                    }
                    if hit { groupNativeMatched[group, default: 0] += 1 }
                }
            }
            for (key, _) in metrics {
                if let group = Self.group(forKey: key) {
                    metrics[key]?.native = groupNative[group] ?? 0
                    metrics[key]?.nativeMatched = groupNativeMatched[group] ?? 0
                }
            }
            return metrics
        }

        var validFalsePositives: Int {
            validFindings.filter { $0.severity == .error }.count
        }

        func baseline() -> Baseline {
            Baseline(
                jdkVersion: jdkVersion,
                keys: metrics(),
                validFalsePositives: validFalsePositives,
                mutations: results.map { $0.mutation.id }.sorted()
            )
        }

        func ratchetFailures(baseline: Baseline) -> [String] {
            var failures: [String] = []
            let current = metrics()
            if Set(results.map { $0.mutation.id }) != Set(baseline.mutations) {
                failures.append(
                    "Corpus membership changed (now \(results.map { $0.mutation.id }.sorted()), was \(baseline.mutations)): run with UPDATE_JAVA_PARITY_BASELINE=1 to re-ratchet")
            }
            for (key, base) in baseline.keys.sorted(by: { $0.key < $1.key }) {
                guard let now = current[key] else { continue }
                // Exact fraction comparison: a drop in either ratio is a regression.
                if now.oracleMatched * base.oracle < base.oracleMatched * now.oracle {
                    failures.append("Ratchet: \(key) recall dropped to \(percent(now.oracleMatched, now.oracle)) from \(percent(base.oracleMatched, base.oracle))")
                }
                switch (now.precision, base.precision) {
                case let (currentPrecision?, basePrecision?):
                    if currentPrecision < basePrecision {
                        failures.append("Ratchet: \(key) precision dropped to \(formatPrecision(currentPrecision)) from \(formatPrecision(basePrecision))")
                    }
                case (nil, .some):
                    failures.append("Ratchet: \(key) precision went undefined (no native findings in its group)")
                case (nil, nil), (_?, nil):
                    break // still (or newly) unmeasurable: progress is ratcheted on update
                }
            }
            if validFalsePositives > baseline.validFalsePositives {
                failures.append("Ratchet: valid-corpus false positives rose to \(validFalsePositives) from \(baseline.validFalsePositives)")
            }
            return failures
        }

        func render(baseline: Baseline?) -> String {
            let keyMetrics = metrics()
            var lines = [
                "Java parity scorecard (JDK \(jdkVersion), errors only)",
                "mutations \(results.count) | oracle errors \(results.flatMap(\.oracle).count) | native findings \(results.flatMap(\.native).count) | valid-corpus false positives \(validFalsePositives)",
            ]
            for key in keyMetrics.keys.sorted() {
                let metric = keyMetrics[key]!
                let precision = metric.precision.map(formatPrecision) ?? "n/a (no native rule)"
                lines.append("\(key): recall \(percent(metric.oracleMatched, metric.oracle)) | precision \(precision)")
            }
            let latencies = results.map(\.seconds).sorted()
            if !latencies.isEmpty {
                lines.append("oracle check latency p50 \(format_ms(latencies[latencies.count / 2])) (debug build, informational)")
            }
            for result in results where result.keyMismatch != nil {
                lines.append("ORACLE MISMATCH \(result.mutation.id): \(result.keyMismatch!)")
            }
            for result in results {
                let oracle = result.oracle.map { "\($0.line):\($0.key)" }.joined(separator: ", ")
                let native = result.native.map { "\($0.line):\($0.rule)" }.joined(separator: ", ")
                lines.append("MUT \(result.mutation.id): oracle [\(oracle)] native [\(native)]")
            }
            let validDetails = validFindings.map { "\($0.line):\($0.rule)" }.joined(separator: ", ")
            lines.append("VALID native: [\(validDetails)]")
            if let baseline {
                for failure in ratchetFailures(baseline: baseline) { lines.append(failure) }
                let current = metrics()
                for key in current.keys.sorted() where baseline.keys[key] == nil {
                    lines.append("NEW KEY \(key): run with UPDATE_JAVA_PARITY_BASELINE=1 to ratchet")
                }
                for key in current.keys.sorted() {
                    guard let base = baseline.keys[key], let now = current[key] else { continue }
                    if now.oracleMatched * base.oracle > base.oracleMatched * now.oracle {
                        lines.append("IMPROVED \(key) recall: run with UPDATE_JAVA_PARITY_BASELINE=1 to ratchet")
                    }
                }
                if validFalsePositives < baseline.validFalsePositives {
                    lines.append("IMPROVED valid-corpus false positives: run with UPDATE_JAVA_PARITY_BASELINE=1 to ratchet")
                }
            } else {
                lines.append("no baseline.json: run with UPDATE_JAVA_PARITY_BASELINE=1 to write it")
            }
            return lines.joined(separator: "\n")
        }
    }

    // MARK: - Doc generation

    private static func regenerateParityDoc(report: Scorecard) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let completionBaselineURL = root
            .appendingPathComponent("Tests/PenumbraTests/Fixtures/JavaCompletionCorpus/baseline.json")
        var completionLine = "unknown (baseline.json unreadable)"
        if let data = try? Data(contentsOf: completionBaselineURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let passing = (json["passing"] as? [String])?.count {
            let cases = (try? FileManager.default.contentsOfDirectory(at: completionBaselineURL.deletingLastPathComponent().appendingPathComponent("cases"), includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "java" }.count
            completionLine = "\(passing)/\(cases.map(String.init) ?? "?")"
        }
        let metrics = report.metrics()
        var keyRows = metrics.keys.sorted().map { key -> String in
            let metric = metrics[key]!
            let precision = metric.precision.map(formatPrecision) ?? "n/a"
            return "| `\(key)` | \(percent(metric.oracleMatched, metric.oracle)) | \(precision) | \(metric.oracle) | \(metric.native) |"
        }.joined(separator: "\n")
        if keyRows.isEmpty { keyRows = "_no keys measured yet_" }
        let doc = """
            # Java parity scorecard

            Measured against `javac`, not by feature lists (plan: `~/.claude/plans/java-intelligence-parity.md`
            §2). Regenerated from `Tests/PenumbraTests/Fixtures/JavaParityCorpus/baseline.json` whenever it is
            ratcheted (`UPDATE_JAVA_PARITY_BASELINE=1 swift test --filter JavaParityCorpusTests`); do not hand-edit
            the numbers. This file also carries the completion-corpus score, replacing the missing
            `docs/JAVA_COMPLETION_PLAN.md` the code used to point at.

            JDK under test: \(report.jdkVersion). Error recall/precision only in this phase; type agreement,
            refactoring compile rate and latency gates arrive with their phases.

            ## Error recall and precision per `javac` key

            Recall: the share of `javac` errors the native checker reports on the same line. Precision: the
            share of native findings `javac` agrees with on the same line. Native side: `unresolved-member`
            and `unresolved-type`, both read as the `cant.resolve*` group.

            | key | recall | precision | oracle errors | native findings |
            |---|---|---|---|---|
            \(keyRows)

            ## Valid-corpus false positives

            Native error-severity findings on code `javac` accepts: **\(report.validFalsePositives)** (hard gate: 0
            for every shipped check).

            ## Completion corpus

            Pass count: **\(completionLine)** (`Tests/PenumbraTests/Fixtures/JavaCompletionCorpus`, ratcheted by
            `JavaCompletionCorpusTests`; gap tags live in the case files).

            ## Not yet measured

            - Type agreement against `TypeMirror` (needs the `attribute` oracle request and the Phase 4 engine).
            - Refactoring compile rate (needs the refactoring corpus, Phase 8).
            - Latency gates (need Release PerfHarness runs: native errors for the visible region, warm `javac`
              errors, body re-attribution, completion p95).
            """
        try doc.write(
            to: root.appendingPathComponent("docs/JAVA_PARITY.md"), atomically: true, encoding: .utf8)
    }
}

private func percent(_ matched: Int, _ total: Int) -> String {
    total == 0 ? "n/a" : "\(Int((Double(matched) / Double(total) * 100).rounded()))% (\(matched)/\(total))"
}

private func formatPrecision(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
}

private func format_ms(_ seconds: Double) -> String {
    String(format: "%.0f ms", seconds * 1000)
}
