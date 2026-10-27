import EditorIntelligence
import Foundation
import SwiftIntelligence
import XCTest

/// The Swift parity scorecard (`docs/SWIFT_INTELLIGENCE_ROADMAP.md`, Phase 0): mutated valid
/// sources, labelled by `swiftc`, measured against the native diagnostics.
///
/// Runs only with `SWIFT_PARITY=1` (and a toolchain with `swiftc`); skipped otherwise. The oracle is
/// `swiftc -emit-sil -Onone`, not `-typecheck`: `missing_return_decl`, definite initialisation and
/// unreachable code are SIL diagnostics that `-typecheck` never reaches. Failures are actionable: an
/// oracle key mismatch prints the oracle's actual keys, and a metric regression prints the delta.
///
/// The native side is `SwiftDiagnosticProvider`, which reports syntax problems only, so every type
/// error starts at 0% recall. That is the baseline later phases move. A native rule joins the
/// scorecard by mapping its `Diagnostic.code` to a group in `Scorecard.nativeRuleGroups`.
///
/// `UPDATE_SWIFT_PARITY_BASELINE=1` rewrites `Fixtures/SwiftParityCorpus/baseline.json` and
/// regenerates `docs/SWIFT_PARITY.md` from it. `SWIFT_PARITY_CASE=Prefix` runs a subset (no ratchet
/// comparison then).
final class SwiftParityCorpusTests: XCTestCase {
    // MARK: - Baseline

    struct KeyMetrics: Codable {
        var oracle: Int
        var oracleMatched: Int
        var native: Int
        var nativeMatched: Int

        var precision: Double? { native == 0 ? nil : Double(nativeMatched) / Double(native) }
    }

    struct Baseline: Codable {
        var compiler: String
        var keys: [String: KeyMetrics]
        var validFalsePositives: Int
        var mutations: [String]

        static var url: URL { fixtureRoot.appendingPathComponent("baseline.json") }

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

    /// `Tests/PenumbraTests/Fixtures/SwiftParityCorpus`. The folder is excluded from the test target
    /// (its `.swift` files are inputs, not code), so it is read from the source tree.
    static var fixtureRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/SwiftParityCorpus")
    }

    // MARK: - Run

    private struct NativeFinding {
        let rule: String
        let line: Int
        let severity: DiagnosticSeverity
    }

    private struct MutationResult {
        let mutation: SwiftParityMutator.Mutation
        let oracle: [SwiftParityOracleError]
        var native: [NativeFinding]
        let seconds: Double
        var keyMismatch: String?
    }

    func testParityScorecard() async throws {
        guard ProcessInfo.processInfo.environment["SWIFT_PARITY"] == "1" else {
            throw XCTSkip("Parity corpus runs only with SWIFT_PARITY=1")
        }
        let oracle = try SwiftParityOracle.discover()

        let valid = try loadValidFixtures()
        var mutations = SwiftParityMutator.all()
        let only = ProcessInfo.processInfo.environment["SWIFT_PARITY_CASE"]
        if let only {
            mutations = mutations.filter { $0.id.hasPrefix(only) }
            XCTAssertFalse(mutations.isEmpty, "no mutation matches SWIFT_PARITY_CASE=\(only)")
        }

        for (name, text) in valid.sorted(by: { $0.key < $1.key }) {
            let errors = try oracle.errors(in: text, named: name)
            XCTAssertTrue(errors.isEmpty, "\(name) is not oracle-clean: \(errors)")
        }
        var results: [MutationResult] = []
        for mutation in mutations {
            let base = try XCTUnwrap(valid[mutation.fixture], "\(mutation.fixture) missing")
            guard let mutated = SwiftParityMutator.apply(mutation, to: base) else {
                XCTFail("\(mutation.id): anchor missing in \(mutation.fixture)")
                continue
            }
            let start = Date()
            let errors = try oracle.errors(in: mutated, named: mutation.fixture)
            let seconds = Date().timeIntervalSince(start)
            var result = MutationResult(mutation: mutation, oracle: errors, native: [], seconds: seconds)
            let actual = errors.map(\.key).sorted()
            let expected = mutation.expectedKeys.sorted()
            if actual != expected { result.keyMismatch = "oracle reports \(actual), expected \(expected)" }
            results.append(result)
        }

        var validFindings: [NativeFinding] = []
        for (name, text) in valid.sorted(by: { $0.key < $1.key }) {
            validFindings += await nativeFindings(text: text, name: name)
        }
        for position in results.indices {
            let mutation = results[position].mutation
            guard let mutated = SwiftParityMutator.apply(mutation, to: valid[mutation.fixture]!) else { continue }
            results[position].native = await nativeFindings(text: mutated, name: mutation.fixture)
        }

        let report = Scorecard(results: results, validFindings: validFindings, compiler: oracle.version)
        let rendered = report.render(baseline: Baseline.load())
        print(rendered)
        try? rendered.write(
            to: FileManager.default.temporaryDirectory.appendingPathComponent("swift-parity-scorecard.txt"),
            atomically: true, encoding: .utf8
        )

        for result in results {
            if let mismatch = result.keyMismatch { XCTFail("\(result.mutation.id): \(mismatch)") }
        }

        if only != nil { return }
        if ProcessInfo.processInfo.environment["UPDATE_SWIFT_PARITY_BASELINE"] == "1" {
            try report.baseline().save()
            try Self.regenerateParityDoc(report: report)
            return
        }
        guard let baseline = Baseline.load() else {
            print("NEW BASELINE NEEDED: run with UPDATE_SWIFT_PARITY_BASELINE=1 to write it")
            return
        }
        for failure in report.ratchetFailures(baseline: baseline) { XCTFail(failure) }
    }

    // MARK: - Oracle and native runs

    private func loadValidFixtures() throws -> [String: String] {
        let directory = Self.fixtureRoot.appendingPathComponent("valid")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "no valid fixtures in \(directory.path)")
        var result: [String: String] = [:]
        for file in files { result[file.lastPathComponent] = try String(contentsOf: file, encoding: .utf8) }
        return result
    }

    private func nativeFindings(text: String, name: String) async -> [NativeFinding] {
        let url = URL(fileURLWithPath: "/tmp/swift-parity/\(name)")
        let origin = TextPosition(line: 0, column: 0, utf16Offset: 0)
        let document = Document(
            url: url,
            displayName: name,
            contentSnapshot: TextSnapshot(version: 1, text: text),
            selection: Selection(range: EditorIntelligence.TextRange(start: origin, end: origin)),
            cursor: Cursor(position: origin),
            viewport: Viewport(x: 0, y: 0, width: 800, height: 600),
            languageIdentifier: "swift"
        )
        return await SwiftDiagnosticProvider().diagnostics(for: document).map {
            NativeFinding(rule: $0.code ?? "", line: $0.range.start.line + 1, severity: $0.severity)
        }
    }

    // MARK: - Scorecard and doc

    private struct Scorecard {
        let results: [MutationResult]
        let validFindings: [NativeFinding]
        let compiler: String

        /// Native `Diagnostic.code` → the group it answers. Empty until a native rule reports a
        /// `swiftc` error; `syntax` is deliberately absent (a syntax warning is not an oracle key).
        static let nativeRuleGroups: [String: String] = [:]

        /// Related `swiftc` names that one native rule can answer read as one group.
        static func group(forKey key: String) -> String {
            switch key {
            case "cannot_find_in_scope", "cannot_find_type_in_scope": return "unresolved"
            case "could_not_find_value_member", "could_not_find_type_member": return "no-member"
            case "argument_out_of_order_unnamed_named", "missing_argument_named", "cannot_convert_argument_value":
                return "arguments"
            case "cannot_convert_to_return_type", "optional_not_unwrapped": return "type-mismatch"
            case "missing_return_decl": return "missing-return"
            case "throwing_call_without_try", "async_expr_without_await": return "effects"
            case "type_does_not_conform": return "conformance"
            default: return key
            }
        }

        static func group(forRule rule: String) -> String? { nativeRuleGroups[rule] }

        func metrics() -> [String: KeyMetrics] {
            var oracleByKey: [String: [SwiftParityOracleError]] = [:]
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
                metrics[key] = KeyMetrics(oracle: errors.count, oracleMatched: matched, native: 0, nativeMatched: 0)
            }
            // Precision is per group: every native finding in the group is matched against the group's
            // oracle errors on the same line, then shared by the group's keys.
            var groupNative: [String: Int] = [:]
            var groupNativeMatched: [String: Int] = [:]
            for result in results {
                for finding in result.native {
                    guard let group = Self.group(forRule: finding.rule) else { continue }
                    groupNative[group, default: 0] += 1
                    let hit = result.oracle.contains { Self.group(forKey: $0.key) == group && $0.line == finding.line }
                    if hit { groupNativeMatched[group, default: 0] += 1 }
                }
            }
            for key in metrics.keys {
                let group = Self.group(forKey: key)
                metrics[key]?.native = groupNative[group] ?? 0
                metrics[key]?.nativeMatched = groupNativeMatched[group] ?? 0
            }
            return metrics
        }

        var validFalsePositives: Int { validFindings.filter { $0.severity == .error }.count }

        func baseline() -> Baseline {
            Baseline(
                compiler: compiler,
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
                    "Corpus membership changed (now \(results.map { $0.mutation.id }.sorted()), was \(baseline.mutations)): run with UPDATE_SWIFT_PARITY_BASELINE=1 to re-ratchet")
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
                "Swift parity scorecard (swiftc \(compiler), errors only)",
                "mutations \(results.count) | oracle errors \(results.flatMap(\.oracle).count) | native findings \(results.flatMap(\.native).count) | valid-corpus false positives \(validFalsePositives)",
            ]
            for key in keyMetrics.keys.sorted() {
                let metric = keyMetrics[key]!
                let precision = metric.precision.map(formatPrecision) ?? "n/a (no native rule)"
                lines.append("\(key): recall \(percent(metric.oracleMatched, metric.oracle)) | precision \(precision)")
            }
            let latencies = results.map(\.seconds).sorted()
            if !latencies.isEmpty {
                lines.append("oracle latency p50 \(String(format: "%.0f ms", latencies[latencies.count / 2] * 1000)) (informational)")
            }
            for result in results where result.keyMismatch != nil {
                lines.append("ORACLE MISMATCH \(result.mutation.id): \(result.keyMismatch!)")
            }
            for result in results {
                let oracle = result.oracle.map { "\($0.line):\($0.key)" }.joined(separator: ", ")
                let native = result.native.map { "\($0.line):\($0.rule)" }.joined(separator: ", ")
                lines.append("MUT \(result.mutation.id): oracle [\(oracle)] native [\(native)]")
            }
            lines.append("VALID native: [\(validFindings.map { "\($0.line):\($0.rule)" }.joined(separator: ", "))]")
            if let baseline {
                lines += ratchetFailures(baseline: baseline)
                let current = metrics()
                for key in current.keys.sorted() where baseline.keys[key] == nil {
                    lines.append("NEW KEY \(key): run with UPDATE_SWIFT_PARITY_BASELINE=1 to ratchet")
                }
                for key in current.keys.sorted() {
                    guard let base = baseline.keys[key], let now = current[key] else { continue }
                    if now.oracleMatched * base.oracle > base.oracleMatched * now.oracle {
                        lines.append("IMPROVED \(key) recall: run with UPDATE_SWIFT_PARITY_BASELINE=1 to ratchet")
                    }
                }
                if validFalsePositives < baseline.validFalsePositives {
                    lines.append("IMPROVED valid-corpus false positives: run with UPDATE_SWIFT_PARITY_BASELINE=1 to ratchet")
                }
            } else {
                lines.append("no baseline.json: run with UPDATE_SWIFT_PARITY_BASELINE=1 to write it")
            }
            return lines.joined(separator: "\n")
        }
    }

    // MARK: - Doc generation

    private static func regenerateParityDoc(report: Scorecard) throws {
        // #filePath is Tests/PenumbraTests/SwiftIntelligence/Parity/<file>; five levels up is the root.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let completionDirectory = root.appendingPathComponent("Tests/PenumbraTests/Fixtures/SwiftCorpus")
        var completionLine = "unknown (baseline.json unreadable)"
        var ceilingLine = "not recorded (`SWIFT_PARITY=1 UPDATE_SWIFT_PARITY_BASELINE=1 swift test --filter SwiftSourceKitCeilingTests`)"
        if let data = try? Data(contentsOf: completionDirectory.appendingPathComponent("baseline.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let passing = (json["passing"] as? [String])?.count {
            let cases = ((try? FileManager.default.contentsOfDirectory(
                at: completionDirectory.appendingPathComponent("cases"), includingPropertiesForKeys: nil
            )) ?? []).filter { $0.pathExtension == "swift" }
            var gapCounts: [String: Int] = [:]
            for file in cases {
                guard let text = try? String(contentsOf: file, encoding: .utf8),
                      let line = text.components(separatedBy: "\n").first(where: { $0.hasPrefix("//! gap: ") }) else { continue }
                gapCounts[String(line.dropFirst("//! gap: ".count)), default: 0] += 1
            }
            let gaps = gapCounts.sorted { ($1.value, $0.key) < ($0.value, $1.key) }
                .map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            completionLine = "\(passing)/\(cases.count)" + (gaps.isEmpty ? "" : "; known gaps by tag: \(gaps)")
            if let data = try? Data(contentsOf: SwiftSourceKitCeilingTests.baselineURL),
               let ceiling = try? JSONDecoder().decode(SwiftSourceKitCeilingTests.CeilingBaseline.self, from: data) {
                ceilingLine = "**\(ceiling.passing.count)/\(cases.count)** through sourcekit-lsp (\(ceiling.toolchain)); "
                    + (ceiling.inconclusive.isEmpty
                        ? "none inconclusive"
                        : "\(ceiling.inconclusive.count) inconclusive, the server's list was incomplete and the case names "
                            + "no word to type (\(ceiling.inconclusive.joined(separator: ", ")))")
            }
        }
        let metrics = report.metrics()
        var keyRows = metrics.keys.sorted().map { key -> String in
            let metric = metrics[key]!
            let precision = metric.precision.map(formatPrecision) ?? "n/a"
            return "| `\(key)` | \(Scorecard.group(forKey: key)) | \(percent(metric.oracleMatched, metric.oracle)) | \(precision) | \(metric.oracle) | \(metric.native) |"
        }.joined(separator: "\n")
        if keyRows.isEmpty { keyRows = "_no keys measured yet_" }
        let doc = """
            # Swift parity scorecard

            Measured against `swiftc`, not by feature lists (roadmap: `docs/SWIFT_INTELLIGENCE_ROADMAP.md`).
            Regenerated from `Tests/PenumbraTests/Fixtures/SwiftParityCorpus/baseline.json` whenever it is
            ratcheted (`SWIFT_PARITY=1 UPDATE_SWIFT_PARITY_BASELINE=1 swift test --filter SwiftParityCorpusTests`);
            do not hand-edit the numbers.

            Compiler under test: Apple Swift \(report.compiler). The oracle is `swiftc -emit-sil -Onone`
            with `-Xfrontend -debug-diagnostic-names`, so SIL diagnostics such as `missing_return_decl` are
            labelled too. Error recall and precision only in this phase.

            ## Error recall and precision per `swiftc` diagnostic

            Recall: the share of `swiftc` errors the native checker reports on the same line. Precision: the
            share of native findings `swiftc` agrees with on the same line, per group. Native side today:
            `SwiftDiagnosticProvider`, which reports syntax problems only, so every type error is at 0%
            until a native rule maps its code to a group.

            | key | group | recall | precision | oracle errors | native findings |
            |---|---|---|---|---|---|
            \(keyRows)

            ## Valid-corpus false positives

            Native error-severity findings on code `swiftc` accepts: **\(report.validFalsePositives)** (hard gate: 0
            for every shipped check).

            ## Completion corpus

            Pass count: **\(completionLine)** (`Tests/PenumbraTests/Fixtures/SwiftCorpus`, ratcheted by
            `NativeCompletionCorpusTests`; gap tags live in the case files).

            Semantic ceiling, the same cases: \(ceilingLine). The gap between the two numbers is what the
            native tier cannot yet answer on its own (`SwiftSourceKitCeilingTests`).

            ## Not yet measured

            - SourceKit-LSP as a second column for diagnostics (completion is measured above).
            - Refactoring compile rate (needs the refactoring corpus, roadmap Phase 5).
            - Latency gates (need Release PerfHarness runs).
            """
        try doc.write(to: root.appendingPathComponent("docs/SWIFT_PARITY.md"), atomically: true, encoding: .utf8)
    }
}

/// One `swiftc` error: its `-debug-diagnostic-names` name and 1-based line.
struct SwiftParityOracleError {
    let key: String
    let line: Int
}

/// `swiftc` as the oracle. Blocking by design: a test process, one short compile per call.
struct SwiftParityOracle {
    let sdkPath: String
    let version: String

    /// Skips (rather than fails) without a toolchain.
    static func discover() throws -> SwiftParityOracle {
        guard let found = try? run(["--find", "swiftc"]), found.status == 0 else {
            throw XCTSkip("No swiftc on this machine")
        }
        let sdk = try run(["--show-sdk-path"])
        let versionText = try run(["swiftc", "--version"]).output
        let version = versionText.range(of: #"version ([0-9.]+)"#, options: .regularExpression)
            .map { String(versionText[$0]).replacingOccurrences(of: "version ", with: "") } ?? "unknown"
        return SwiftParityOracle(sdkPath: sdk.output.trimmingCharacters(in: .whitespacesAndNewlines), version: version)
    }

    /// The compiler's errors for `text`, written to a file named `name` in a fresh folder.
    func errors(in text: String, named name: String) throws -> [SwiftParityOracleError] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-parity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(name)
        try text.write(to: file, atomically: true, encoding: .utf8)
        let result = try Self.run([
            "swiftc", "-emit-sil", "-Onone", "-o", "/dev/null", "-sdk", sdkPath,
            "-diagnostic-style", "llvm", "-Xfrontend", "-debug-diagnostic-names", file.path,
        ])
        let pattern = try NSRegularExpression(pattern: #"^(.+?):(\d+):\d+: error: .*\[([a-z_0-9]+)\]$"#, options: .anchorsMatchLines)
        let output = result.output as NSString
        return pattern.matches(in: result.output, range: NSRange(location: 0, length: output.length))
            .compactMap { match in
                guard let line = Int(output.substring(with: match.range(at: 2))) else { return nil }
                return SwiftParityOracleError(key: output.substring(with: match.range(at: 3)), line: line)
            }
            .sorted { ($0.line, $0.key) < ($1.line, $1.key) }
    }

    private static func run(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

private func percent(_ matched: Int, _ total: Int) -> String {
    total == 0 ? "n/a" : "\(Int((Double(matched) / Double(total) * 100).rounded()))% (\(matched)/\(total))"
}

private func formatPrecision(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
}
