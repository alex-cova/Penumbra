import XCTest
import EditorIntelligence
@testable import JavaIntelligence

/// javac is the oracle for the two call-site hint kinds.
///
/// **Parameter names.** javac picks the overload each call binds to, and `javap -c` shows it as a
/// method descriptor. The names the hints must show are the names of that overload's parameters, which
/// each sample declares in declaration order (the order `javap -s` lists them). The provider may show
/// exactly those names or nothing for a call (it skips a call it cannot bind to one declaration), but
/// never other names. A call listed in `knownGaps` may show nothing, and the test fails if one that is
/// not listed does, so a gap cannot grow unnoticed.
///
/// **Method chains.** For a chain broken over lines, javac gives the type of each prefix. A hint after a
/// call must name that call's type, and appears exactly where the type differs from the one before it.
final class JavaInlayHintCallOracleTests: XCTestCase {
    // MARK: - Parameter names

    private struct Declaration {
        let params: [String]
        var isVarargs = false
    }

    private static let api = """
    class Api {
        Api(int width, String label) {}
        static void over(int first) {}
        static void over(int first, int second) {}
        static void over(String text, int count) {}
        static void over(long big, long bigger) {}
        static void over(double ratio) {}
        static void many(String head, int... tail) {}
        static void box(Integer value, Object other) {}
        static void mixed(Object any, String text) {}
        static void mixed(String text, Object any) {}
        void inst(int amount, boolean flag) {}
        static void narrow(byte small) {}
        static void narrow(short medium) {}
        static void narrow(int large) {}
        static void shape(Object anything) {}
        static void shape(Number number) {}
        static void shape(Integer boxed) {}
        static void nullable(String text) {}
        static void nullable(Object thing) {}
        void pair(int number, String label) {}
        void pair(String label, int number) {}
        Api(String only) {}
        Api(double ratio) {}
    }
    """

    /// In the order the declarations appear in `api`, so `javap -s` pairs them with descriptors.
    private static let declarations: [Declaration] = [
        Declaration(params: ["width", "label"]),
        Declaration(params: ["first"]),
        Declaration(params: ["first", "second"]),
        Declaration(params: ["text", "count"]),
        Declaration(params: ["big", "bigger"]),
        Declaration(params: ["ratio"]),
        Declaration(params: ["head", "tail"], isVarargs: true),
        Declaration(params: ["value", "other"]),
        Declaration(params: ["any", "text"]),
        Declaration(params: ["text", "any"]),
        Declaration(params: ["amount", "flag"]),
        Declaration(params: ["small"]),
        Declaration(params: ["medium"]),
        Declaration(params: ["large"]),
        Declaration(params: ["anything"]),
        Declaration(params: ["number"]),
        Declaration(params: ["boxed"]),
        Declaration(params: ["text"]),
        Declaration(params: ["thing"]),
        Declaration(params: ["number", "label"]),
        Declaration(params: ["label", "number"]),
        Declaration(params: ["only"]),
        Declaration(params: ["ratio"]),
    ]

    /// Each call is one line ending in `// call`, in the order javac emits the invocations.
    private static let callerBody = """
        Api.over(1); // call
        Api.over(1.5); // call
        Api.over(1, 2); // call
        Api.over(1L, 2); // call
        Api.over("s", 3); // call
        Api.over(2.0f); // call
        Api.many("h", 1, 2); // call
        Api.many("h"); // call
        Api.box(1, "x"); // call
        Api.mixed("a", 1); // call
        Api.mixed(1, "a"); // call
        Api api = new Api(3, "l"); // call
        api.inst(4, true); // call
        Api.narrow('c'); // call
        Api.narrow((byte) 1); // call
        Api.narrow((short) 2); // call
        Api.narrow(3); // call
        Api.shape(1); // call
        Api.shape(2.5); // call
        Api.shape("s"); // call
        Api.nullable("t"); // call
        Api.nullable(null); // call
        api.pair(1, "a"); // call
        api.pair("a", 1); // call
        Api other = new Api("x"); // call
        Api third = new Api(1.5); // call
    """

    /// Calls the provider may leave without hints, by the text of the call's line. Anything else that
    /// shows nothing fails the test.
    private static let knownGaps: Set<String> = [
        // `null` has no type of its own, so the provider cannot rank the overloads and shows nothing.
        "Api.nullable(null); // call",
    ]

    func testParameterNameHintsFollowTheOverloadJavacChooses() async throws {
        let jdk = try ParityTestSupport.requireJDK()
        guard jdk.hasCtSym, let javac = jdk.javac else { throw XCTSkip("No JDK with ct.sym and javac") }
        let javap = javac.deletingLastPathComponent().appendingPathComponent("javap")
        guard FileManager.default.isExecutableFile(atPath: javap.path) else { throw XCTSkip("No javap next to javac") }
        let scratch = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let source = Self.api + "\nclass Caller {\n    void m() {\n" + Self.callerBody + "\n    }\n}\n"
        let directory = scratch.appendingPathComponent("classes", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("Api.java")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let compiled = try Self.run(javac, ["-proc:none", "-Xlint:none", "-d", directory.path, file.path])
        XCTAssertEqual(compiled.status, 0, "the sample must compile: \(compiled.error)")

        // `name:descriptor` of `Api`'s members, in declaration order, gives each overload its names.
        let members = try Self.run(javap, ["-p", "-s", "-cp", directory.path, "Api"]).output
        var keys: [String] = []
        var pendingName: String?
        for line in members.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if let range = text.range(of: "descriptor: ") {
                if let pendingName { keys.append("\(pendingName):\(text[range.upperBound...].trimmingCharacters(in: .whitespaces))") }
                pendingName = nil
            } else if text.hasSuffix(";"), let open = text.firstIndex(of: "(") {
                let name = text[..<open].split(separator: " ").last.map(String.init) ?? ""
                pendingName = name == "Api" ? "<init>" : name
            }
        }
        XCTAssertEqual(keys.count, Self.declarations.count, "javap lists \(keys)")
        var byKey: [String: Declaration] = [:]
        for (key, declaration) in zip(keys, Self.declarations) { byKey[key] = declaration }

        // The overload javac bound each call to.
        let code = try Self.run(javap, ["-c", "-p", "-cp", directory.path, "Caller"]).output
        let invocation = try NSRegularExpression(pattern: #"// Method Api\.("?[\w$<>]+"?):(\([^)]*\)\S+)"#)
        let chosen: [String] = code.split(separator: "\n").compactMap { line in
            let text = String(line)
            guard let match = invocation.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let nameRange = Range(match.range(at: 1), in: text),
                  let descriptorRange = Range(match.range(at: 2), in: text) else { return nil }
            return "\(text[nameRange].replacingOccurrences(of: "\"", with: "")):\(text[descriptorRange])"
        }
        let callLines = source.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            .filter { $0.element.hasSuffix("// call") }
        XCTAssertEqual(chosen.count, callLines.count, "one invocation per call line: \(chosen)")

        let provider = try await Self.provider(source: source, jdk: jdk, scratch: scratch)
        await provider.setOptions(JavaInlayHintOptions(parameterNames: true, variableTypes: false))
        let hints = await Self.hints(for: source, provider: provider, in: scratch).filter { $0.kind == .parameter }
        let lineStarts = Self.lineStarts(of: source)

        var failures: [String] = []
        for ((lineIndex, line), descriptor) in zip(callLines, chosen) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let declaration = byKey[descriptor] else {
                failures.append("\(text): javac chose \(descriptor), which no declaration matches")
                continue
            }
            let names = declaration.isVarargs ? Array(declaration.params.dropLast()) : declaration.params
            let expected = names.prefix(Self.argumentCount(of: text)).map { "\($0):" }
            let start = lineStarts[lineIndex]
            let end = lineIndex + 1 < lineStarts.count ? lineStarts[lineIndex + 1] : (source as NSString).length
            let actual = hints.filter { $0.utf16Offset >= start && $0.utf16Offset < end }
                .sorted { $0.utf16Offset < $1.utf16Offset }.map(\.label)
            if actual == expected { continue }
            if actual.isEmpty, Self.knownGaps.contains(text) { continue }
            failures.append("\(text): javac chose \(descriptor) so \(expected), hints \(actual)")
        }
        XCTAssertEqual(failures, [], failures.joined(separator: "\n"))
    }

    /// The number of top-level arguments in the first call on a line.
    private static func argumentCount(of line: String) -> Int {
        guard let open = line.firstIndex(of: "(") else { return 0 }
        var depth = 0
        var count = 1
        var quoted = false
        for character in line[open...] {
            if character == "\"" { quoted.toggle() }
            if quoted { continue }
            if character == "(" { depth += 1 }
            if character == ")" {
                depth -= 1
                if depth == 0 { break }
            }
            if character == ",", depth == 1 { count += 1 }
        }
        let inside = line[line.index(after: open)...].prefix { $0 != ")" }
        return inside.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : count
    }

    // MARK: - Method chains

    private struct Chain {
        let name: String
        let imports: String
        let parameters: String
        /// The links; each after the first starts with `.`.
        let links: [String]
    }

    private static let chains: [Chain] = [
        Chain(name: "StreamPipeline", imports: "import java.util.List;", parameters: "List<String> names", links: [
            "names.stream()", ".map(String::length)", ".filter(n -> n > 1)", ".toList()",
        ]),
        Chain(name: "OptionalMaps", imports: "import java.util.Optional;", parameters: "Optional<String> held", links: [
            "held.map(String::trim)", ".map(String::length)", ".filter(n -> n > 0)", ".get()",
        ]),
        Chain(name: "StringBuilderStaysTheSame", imports: "", parameters: "StringBuilder sb", links: [
            "sb.append(1)", ".append(\"x\")", ".reverse()", ".toString()",
        ]),
        Chain(name: "CollectToList", imports: "import java.util.List;\nimport java.util.stream.Collectors;", parameters: "List<String> names", links: [
            "names.stream()", ".sorted()", ".collect(Collectors.toList())", ".size()",
        ]),
        Chain(name: "StringChain", imports: "", parameters: "String text", links: [
            "text.trim()", ".toUpperCase()", ".chars()", ".sum()",
        ]),
        Chain(name: "MapEntries", imports: "import java.util.Map;", parameters: "Map<String, Integer> map", links: [
            "map.entrySet()", ".stream()", ".map(entry -> entry.getKey())", ".findFirst()", ".get()",
        ]),
    ]

    /// Links whose hint the provider may leave out, as `Chain.name#link`. Anything else that is missing fails.
    private static let knownChainGaps: Set<String> = []

    func testChainHintsFollowTheTypesJavacGivesEachPrefix() async throws {
        let jdk = try ParityTestSupport.requireJDK()
        guard jdk.hasCtSym, let javac = jdk.javac else { throw XCTSkip("No JDK with ct.sym and javac") }
        let scratch = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let provider = try await Self.provider(source: "", jdk: jdk, scratch: scratch)
        await provider.setOptions(JavaInlayHintOptions(parameterNames: false, variableTypes: false, methodChainTypes: true))

        var failures: [String] = []
        for chain in Self.chains {
            // javac: the type of every prefix of the chain.
            var types: [String?] = []
            for link in chain.links.indices {
                let prefix = chain.links[0...link].joined(separator: "\n            ")
                let probe = """
                \(chain.imports)
                class P { void m(\(chain.parameters)) {
                    var p = \(prefix);
                    p.zzProbe();
                } }
                """
                types.append(try Self.javacType(ofProbe: probe, named: "P", javac: javac, in: scratch))
            }
            // The provider, on the same chain written over lines.
            var source = "\(chain.imports)\nclass C { void m(\(chain.parameters)) {\n    var result = "
            var endOffsets: [Int] = []
            for (position, link) in chain.links.enumerated() {
                source += position == 0 ? link : "\n        " + link
                endOffsets.append((source as NSString).length)
            }
            source += ";\n} }\n"
            let hints = await Self.hints(for: source, provider: provider, in: scratch).filter { $0.kind == .type }
            for link in chain.links.indices {
                let key = "\(chain.name)#\(link)"
                let atLink = hints.filter { $0.utf16Offset == endOffsets[link] }
                // A hint follows a call whose receiver is itself a call and that has another link after it.
                let eligible = link >= 1 && link < chain.links.count - 1
                var expected: String?
                if eligible, let current = types[link], let before = types[link - 1] {
                    let now = JavaReceiverTypeAudit.simplified(current)
                    if now != JavaReceiverTypeAudit.simplified(before), now != "Object" { expected = ": " + now }
                }
                // The label is `: Type`; `simplified` normalizes the type after the colon.
                let actual = atLink.map { ": " + JavaReceiverTypeAudit.simplified(String($0.label.dropFirst(2))) }
                switch (expected, actual.first) {
                case (nil, nil):
                    break
                case (nil, let found?):
                    failures.append("\(key): javac gives no new type here, hint \(found)")
                case (let want?, nil):
                    if !Self.knownChainGaps.contains(key) { failures.append("\(key): javac \(want), no hint") }
                case (let want?, let found?):
                    if want != found { failures.append("\(key): javac \(want), hint \(found)") }
                }
            }
        }
        XCTAssertEqual(failures, [], failures.joined(separator: "\n"))
    }

    // MARK: - Shared

    private static func makeScratch() throws -> URL {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("inlay-call-oracle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        return scratch
    }

    /// A provider over the JDK's classes and, for `source`, its own types as the app's index overlay holds them.
    private static func provider(source: String, jdk: JDKInstallation, scratch: URL) async throws -> JavaInlayHintProvider {
        let jdkShard = scratch.appendingPathComponent("jdk.idx")
        try JavaIndexShardWriter().write(
            try JDKCtSymRoot(installation: jdk).readStubs(), stamp: JavaStamp(size: 0, modificationDate: 0), to: jdkShard
        )
        let index = JavaIndex()
        await index.setSources([.init(precedence: 3, reader: try JavaIndexShardReader(url: jdkShard))])
        let own = JavaSourceStubBuilder.build(source: source, url: scratch.appendingPathComponent("T.java")).classes
        await index.setOverlay(Dictionary(uniqueKeysWithValues: own.map { ($0.qualifiedName, $0) }))
        return JavaInlayHintProvider(index: index, indexPaths: JavaIndexPaths(root: scratch.appendingPathComponent("cache")))
    }

    private static func hints(for source: String, provider: JavaInlayHintProvider, in scratch: URL) async -> [InlayHint] {
        let start = JavaNavigationText.position(utf16Offset: 0, in: source)
        let end = JavaNavigationText.position(utf16Offset: (source as NSString).length, in: source)
        let document = Document(
            url: scratch.appendingPathComponent("T.java"), displayName: "T.java",
            contentSnapshot: TextSnapshot(version: 0, text: source),
            selection: Selection(range: EditorIntelligence.TextRange(start: start, end: start)),
            cursor: Cursor(position: start),
            viewport: Viewport(x: 0, y: 0, width: 10, height: 10),
            languageIdentifier: "java"
        )
        return await provider.inlayHints(for: document, in: EditorIntelligence.TextRange(start: start, end: end))
    }

    private static func lineStarts(of source: String) -> [Int] {
        var starts = [0]
        let text = source as NSString
        for index in 0..<text.length where text.character(at: index) == 0x0A { starts.append(index + 1) }
        return starts
    }

    private static func run(_ executable: URL, _ arguments: [String]) throws -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Read both before waiting, so a full pipe cannot stall the child.
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output, error)
    }

    /// The probed variable's type from a `p.zzProbe()` compile error: a reference type from
    /// `location: variable p of type T`, or a primitive from `T cannot be dereferenced`.
    private static func javacType(ofProbe source: String, named name: String, javac: URL, in scratch: URL) throws -> String? {
        let directory = scratch.appendingPathComponent("probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(name).java")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let output = try run(javac, ["-proc:none", "-Xlint:none", "-d", directory.path, "-Xmaxerrs", "40", file.path]).error
        for pattern in [
            "symbol:\\s+method zzProbe\\(\\)\\s+location: variable \\w+ of type (.+)",
            "([\\w.$\\[\\]]+) cannot be dereferenced",
        ] {
            let regex = try NSRegularExpression(pattern: pattern)
            if let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
               let range = Range(match.range(at: 1), in: output) {
                return output[range].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
}
