import Foundation
import XCTest
@testable import JavaIntelligence

/// Release-aware platform resolution against `javac`, on every installed JDK: each JDK at its own
/// platform, with `--release 8/11/17/21` below it, and with `-source 8 -target 8` (which must
/// *not* restrict the API). Umbra indexes what the app indexes (`JDKIndexRoot` for the JDK's own
/// platform, `JDKPlatformRoot` for a release) and answers each probe through the index and
/// `JavaMemberLookup` under the module's platform scope, at class and member level.
///
/// One `javac` run per configuration compiles every probe (one method each) and the errors are
/// mapped back to probes by line. Semantic comparison only: does the probe compile.
///
/// `DIFF` lines print every disagreement and `PLATFORMSUMMARY` the counts per configuration:
/// - `falsePositive`: Umbra rejects what `javac` accepts. Fails.
/// - `falseNegative`: Umbra accepts what `javac` rejects. Fails unless the probe declares a gap.
/// - `unsupported`: a declared gap (`gap:` on the probe); printed, never fails.
///
/// Skipped without a JDK; configurations a JDK cannot run are reported as `UNAVAILABLE`.
final class JavaPlatformReleaseDifferentialTests: XCTestCase {
    enum Check {
        case type(String)
        case staticMember(String, String)
        case instanceMember(String, String)
        /// The method resolves and returns this simple type name (a covariant override).
        case returns(String, String, String)
    }

    struct Probe {
        let name: String
        let statement: String
        let check: Check
        /// A known, explained difference: printed as `unsupported`, never fails.
        var gap: String? = nil
        /// A known difference only under `-source` below 9 without `--release`.
        var legacySourceGap: String? = nil
    }

    static let probes: [Probe] = [
        Probe(name: "ListType", statement: "java.util.List<String> x = null;", check: .type("java.util.List")),
        Probe(name: "JAXBContext", statement: "javax.xml.bind.JAXBContext x = null;", check: .type("javax.xml.bind.JAXBContext")),
        Probe(name: "GeneratedAnnotation", statement: "javax.annotation.Generated x = null;", check: .type("javax.annotation.Generated")),
        Probe(name: "HttpClient", statement: "java.net.http.HttpClient x = null;", check: .type("java.net.http.HttpClient")),
        Probe(name: "Flow", statement: "java.util.concurrent.Flow x = null;", check: .type("java.util.concurrent.Flow")),
        Probe(name: "Record", statement: "java.lang.Record x = null;", check: .type("java.lang.Record")),
        Probe(name: "SequencedCollection", statement: "java.util.SequencedCollection<String> x = null;", check: .type("java.util.SequencedCollection")),
        Probe(name: "LangCompiler", statement: "java.lang.Compiler x = null;", check: .type("java.lang.Compiler")),
        Probe(name: "UnsupportedUnsafe", statement: "sun.misc.Unsafe x = null;", check: .type("sun.misc.Unsafe")),
        Probe(name: "InternalUnsafe", statement: "jdk.internal.misc.Unsafe x = null;", check: .type("jdk.internal.misc.Unsafe"),
              legacySourceGap: "javac below -source 9 compiles without module encapsulation and sees non-exported JDK packages; Umbra indexes the exported API only"),
        Probe(name: "ListOf", statement: "java.util.List.of(\"a\");", check: .staticMember("java.util.List", "of")),
        Probe(name: "MapEntry", statement: "java.util.Map.entry(\"a\", 1);", check: .staticMember("java.util.Map", "entry")),
        Probe(name: "ComparatorComparing", statement: "java.util.Comparator.comparing((String s) -> s.length());", check: .staticMember("java.util.Comparator", "comparing")),
        Probe(name: "CollectorsTeeing", statement: "java.util.stream.Collectors.teeing(null, null, null);", check: .staticMember("java.util.stream.Collectors", "teeing")),
        Probe(name: "ThreadOfVirtual", statement: "Thread.ofVirtual();", check: .staticMember("java.lang.Thread", "ofVirtual")),
        Probe(name: "MathClamp", statement: "Math.clamp(1L, 0, 2);", check: .staticMember("java.lang.Math", "clamp")),
        Probe(name: "StringIsBlank", statement: "\"\".isBlank();", check: .instanceMember("java.lang.String", "isBlank")),
        Probe(name: "StringRepeat", statement: "\"\".repeat(2);", check: .instanceMember("java.lang.String", "repeat")),
        Probe(name: "StringFormatted", statement: "\"%s\".formatted(1);", check: .instanceMember("java.lang.String", "formatted")),
        Probe(name: "OptionalIsEmpty", statement: "java.util.Optional.empty().isEmpty();", check: .instanceMember("java.util.Optional", "isEmpty")),
        Probe(name: "StreamToList", statement: "java.util.stream.Stream.of(1).toList();", check: .instanceMember("java.util.stream.Stream", "toList")),
        Probe(name: "InheritedDefaultStream", statement: "new java.util.ArrayList<String>().stream();", check: .instanceMember("java.util.ArrayList", "stream")),
        Probe(name: "InheritedDefaultReversed", statement: "new java.util.ArrayList<String>().reversed();", check: .instanceMember("java.util.ArrayList", "reversed")),
        Probe(name: "InheritedAppend", statement: "new StringBuilder().append(1).length();", check: .instanceMember("java.lang.StringBuilder", "append")),
        Probe(name: "CovariantFlip", statement: "java.nio.ByteBuffer x = java.nio.ByteBuffer.allocate(1).flip();", check: .returns("java.nio.ByteBuffer", "flip", "ByteBuffer")),
    ]

    enum Kind: String { case match, falsePositive, falseNegative, unsupported }

    struct Configuration {
        let label: String
        let javacFlags: [String]
        var isLegacySource = false
        /// The platform release the module's scope names; `nil` is the JDK's own platform.
        let release: Int?
    }

    func testUmbraMatchesJavacPerRelease() async throws {
        let jdks = JDKLocator().discoverAll().filter { $0.javac != nil }
        try XCTSkipIf(jdks.isEmpty, "needs an installed JDK")
        var byVersion: [Int: JDKInstallation] = [:]
        for jdk in jdks where byVersion[jdk.featureVersion] == nil { byVersion[jdk.featureVersion] = jdk }
        print("PLATFORMJDKS \(byVersion.keys.sorted())")
        for wanted in [8, 17] where byVersion[wanted] == nil {
            print("UNAVAILABLE JDK \(wanted) is not installed: its rows (JDK \(wanted), --release 8; JDK 8, source/target 8) were not run")
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("platform-diff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var failures: [String] = []
        for version in byVersion.keys.sorted() {
            let jdk = byVersion[version]!
            let work = scratch.appendingPathComponent("jdk\(version)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let supported = JDKPlatformRoot.supportedReleases(of: jdk)
            var configurations = [Configuration(label: "own", javacFlags: [], release: nil)]
            if version > 8 {
                configurations.append(Configuration(label: "source8", javacFlags: ["-source", "8", "-target", "8", "-Xlint:-options"], isLegacySource: true, release: nil))
            }
            for release in [8, 11, 17, 21] where release <= version {
                guard release == version || supported.contains(release) else {
                    print("UNAVAILABLE jdk=\(version) --release \(release): not in this JDK's ct.sym")
                    continue
                }
                configurations.append(Configuration(label: "release\(release)", javacFlags: ["--release", String(release)], release: release))
            }
            let index = try await makeIndex(jdk: jdk, releases: configurations.compactMap(\.release), work: work)
            for configuration in configurations {
                let javacAccepts = try runJavac(jdk: jdk, configuration: configuration, work: work)
                var counts: [Kind: Int] = [:]
                for probe in Self.probes {
                    let umbraAccepts = await umbraAccepts(probe.check, release: configuration.release, jdk: jdk, index: index)
                    let accepted = javacAccepts[probe.name] ?? false
                    let gap = probe.gap ?? (configuration.isLegacySource ? probe.legacySourceGap : nil)
                    let kind: Kind
                    switch (accepted, umbraAccepts) {
                    case (true, true), (false, false): kind = .match
                    case (true, false): kind = gap != nil ? .unsupported : .falsePositive
                    case (false, true): kind = gap != nil ? .unsupported : .falseNegative
                    }
                    counts[kind, default: 0] += 1
                    guard kind != .match else { continue }
                    let line = "jdk=\(version) \(configuration.label) \(probe.name) \(kind.rawValue) javac=\(accepted) umbra=\(umbraAccepts)\(gap.map { " gap: \($0)" } ?? "")"
                    print("DIFF \(line)")
                    if kind == .falsePositive || kind == .falseNegative { failures.append(line) }
                }
                print("PLATFORMSUMMARY jdk=\(version) \(configuration.label) "
                      + counts.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: " "))
            }
        }
        XCTAssertEqual(failures, [], "undeclared disagreements with javac")
    }

    /// Two modules on one index, one on `--release 8` and one on the JDK's own platform, queried
    /// interleaved: each keeps its own answers.
    func testTwoModulesOnDifferentReleasesShareOneIndex() async throws {
        guard let jdk = JDKLocator().discoverAll().filter({ $0.javac != nil && $0.featureVersion >= 11 })
            .first(where: { JDKPlatformRoot.supportedReleases(of: $0).contains(8) }) else {
            throw XCTSkip("needs a JDK 11+ whose ct.sym holds release 8")
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("platform-two-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let index = try await makeIndex(jdk: jdk, releases: [8], work: work)
        for _ in 0..<3 {
            let legacyJAXB = await umbraAccepts(.type("javax.xml.bind.JAXBContext"), release: 8, jdk: jdk, index: index)
            let modernJAXB = await umbraAccepts(.type("javax.xml.bind.JAXBContext"), release: nil, jdk: jdk, index: index)
            let legacyOf = await umbraAccepts(.staticMember("java.util.List", "of"), release: 8, jdk: jdk, index: index)
            let modernOf = await umbraAccepts(.staticMember("java.util.List", "of"), release: nil, jdk: jdk, index: index)
            XCTAssertTrue(legacyJAXB)
            XCTAssertFalse(modernJAXB)
            XCTAssertFalse(legacyOf)
            XCTAssertTrue(modernOf)
        }
    }

    /// Every JDK with a ct.sym: the releases it reports are the letters with signatures, the
    /// JDK's own release is read from its platform (not ct.sym) when ct.sym lacks it, and release
    /// 8's API has JAXB and no `List.of`.
    func testCtSymReleaseRoots() throws {
        let jdks = JDKLocator().discoverAll().filter(\.hasCtSym)
        try XCTSkipIf(jdks.isEmpty, "needs a JDK with ct.sym")
        for jdk in jdks {
            let supported = JDKPlatformRoot.supportedReleases(of: jdk)
            print("CTSYM \(jdk.displayName) releases=\(supported.sorted())")
            XCTAssertTrue(supported.isSuperset(of: Set(max(8, jdk.featureVersion - 11)..<jdk.featureVersion)), jdk.displayName)
            guard supported.contains(8), let made = JDKPlatformRoot.make(for: jdk, release: 8) else { continue }
            let stubs = try made.root.readStubs()
            let byName = Dictionary(stubs.map { ($0.qualifiedName, $0) }, uniquingKeysWith: { first, _ in first })
            XCTAssertNotNil(byName["javax.xml.bind.JAXBContext"], jdk.displayName)
            XCTAssertNil(byName["java.net.http.HttpClient"], jdk.displayName)
            let list = try XCTUnwrap(byName["java.util.List"], jdk.displayName)
            XCTAssertFalse(list.methods.contains { $0.name == "of" }, jdk.displayName)
            XCTAssertNotEqual(made.kind, JDKIndexRoot.make(for: jdk).kind, "release 8 has its own shard kind")
        }
    }

    // MARK: - Umbra side

    private func umbraAccepts(_ check: Check, release: Int?, jdk: JDKInstallation, index: JavaIndex) async -> Bool {
        let scope: Set<String>? = release.map { [JavaPlatformScope.token(release: $0)] } ?? []
        let context = JavaResolutionContext(packageName: "app", imports: [], enclosingTypeQualifiedNames: ["app.Probes"])
        return await JavaIndex.$queryScope.withValue(scope) {
            func members(_ owner: String, _ mode: JavaMemberLookupMode) async -> [JavaResolvedMember] {
                await JavaMemberLookup.members(of: .classType(qualifiedName: owner, arguments: [], outer: nil), mode: mode, context: context, index: index)
            }
            switch check {
            case .type(let name):
                guard await index.classStub(qualifiedName: name) != nil else { return false }
                return await index.isExportedToQuery(qualifiedName: name)
            case .staticMember(let owner, let name):
                return await members(owner, .staticOnly).contains { $0.name == name }
            case .instanceMember(let owner, let name):
                return await members(owner, .instance).contains { $0.name == name }
            case .returns(let owner, let name, let expected):
                for member in await members(owner, .instance) {
                    if case .method(let method, _) = member, method.name == name, method.parameters.isEmpty {
                        return method.returnType.simpleDisplayName == expected
                    }
                }
                return false
            }
        }
    }

    private func makeIndex(jdk: JDKInstallation, releases: [Int], work: URL) async throws -> JavaIndex {
        var sources: [JavaIndex.Source] = []
        let (root, _) = JDKIndexRoot.make(for: jdk)
        let own = work.appendingPathComponent("own.idx")
        try JavaIndexShardWriter().write(try root.readStubs(), stamp: JavaStamp(size: 0, modificationDate: 0), to: own)
        sources.append(.init(precedence: 3, reader: try JavaIndexShardReader(url: own),
                             shardPath: JavaPlatformScope.token(release: jdk.featureVersion), isDefaultPlatform: true))
        for release in Set(releases) where release != jdk.featureVersion {
            let made = try XCTUnwrap(JDKPlatformRoot.make(for: jdk, release: release))
            let url = work.appendingPathComponent("release-\(release).idx")
            try JavaIndexShardWriter().write(try made.root.readStubs(), stamp: JavaStamp(size: 0, modificationDate: 0), to: url)
            sources.append(.init(precedence: 3, reader: try JavaIndexShardReader(url: url), shardPath: JavaPlatformScope.token(release: release)))
        }
        let index = JavaIndex()
        await index.setSources(sources)
        return index
    }

    // MARK: - javac side

    /// Compiles every probe as its own method and returns which compiled without an error.
    private func runJavac(jdk: JDKInstallation, configuration: Configuration, work: URL) throws -> [String: Bool] {
        let dir = work.appendingPathComponent("case-\(configuration.label)", isDirectory: true)
        let file = dir.appendingPathComponent("app/Probes.java")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var lines = ["package app;", "@SuppressWarnings(\"all\")", "class Probes {"]
        var lineOfProbe: [Int: String] = [:]
        for probe in Self.probes {
            lines.append("    void probe\(probe.name)() {")
            lines.append("        \(probe.statement)")
            lineOfProbe[lines.count] = probe.name
            lines.append("    }")
        }
        lines.append("}")
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        let arguments = ["-XDrawDiagnostics", "-Xmaxerrs", "1000", "-proc:none", "-implicit:none",
                         "-d", dir.appendingPathComponent("out").path] + configuration.javacFlags + [file.path]
        let output = try run(jdk.javac!, arguments)
        var accepted = Dictionary(uniqueKeysWithValues: Self.probes.map { ($0.name, true) })
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false)
            guard parts.count >= 4, let number = Int(parts[1]) else { continue }
            guard parts[3].trimmingCharacters(in: .whitespaces).hasPrefix("compiler.err") else { continue }
            if let name = lineOfProbe[number] { accepted[name] = false }
        }
        return accepted
    }

    @discardableResult
    private func run(_ executable: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
