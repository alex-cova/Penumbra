import XCTest
import EditorIntelligence
@testable import JavaIntelligence

/// Runs the golden Go to Definition corpus (`Fixtures/JavaNavigationCorpus/cases`) against the
/// real JDK plus the fixture project (`Fixtures/JavaNavigationCorpus/project`).
///
/// Each case marks the clicked position with `/*|*/` and states what it expects in `//! key: value`
/// lines:
///
/// - `target: model/Dog.java:fetch` — some returned location is in a file ending with that path and
///   selects that text. `self:name` means the case file itself.
/// - `targets: 2` — exactly that many locations (a choice popup). Without it, `target` expects one.
/// - `none` — the click resolves to nothing.
/// - `package-dirs: com/acme/model` — every returned location is a directory whose path ends with
///   one of these, and each of these is returned (a package segment).
/// - `package: java.util` — a single package location for a package with no project directory.
///
/// A case tagged `gap: Name` is a known failure; it never fails the test, and the scorecard says
/// when it starts passing so the tag can be removed. A case listed in `baseline.json` must keep
/// passing. `UPDATE_JAVA_NAVIGATION_BASELINE=1 swift test --filter JavaNavigationCorpusTests`
/// rewrites the baseline; `JAVA_NAVIGATION_CASE=Method,Field` runs the cases with those prefixes.
final class JavaNavigationCorpusTests: XCTestCase {
    private static let indexTask = Task { try await NavigationCorpusIndex.build() }

    func testCorpus() async throws {
        let corpus: NavigationCorpusIndex
        do {
            corpus = try await Self.indexTask.value
        } catch is NavigationCorpusIndex.NoJDK {
            throw XCTSkip("No JDK with ct.sym found on this machine")
        }
        var cases = try CompletionCorpusRunner.Case.load(from: corpus.casesDirectory, extension: "java")
        let only = ProcessInfo.processInfo.environment["JAVA_NAVIGATION_CASE"]
        if let only {
            let prefixes = only.split(separator: ",").map(String.init)
            cases = cases.filter { corpusCase in prefixes.contains { corpusCase.name.hasPrefix($0) } }
        } else {
            XCTAssertGreaterThan(cases.count, 80)
        }

        var results: [CompletionCorpusRunner.Result] = []
        var gaps: [String: String] = [:]
        for corpusCase in cases {
            if let gap = corpusCase.directives["gap"] { gaps[corpusCase.name] = gap }
            results.append(await run(corpusCase, corpus: corpus))
        }

        let report = Self.scorecard(results: results, gaps: gaps)
        print(report)
        try? report.write(
            to: FileManager.default.temporaryDirectory.appendingPathComponent("java-navigation-scorecard.txt"),
            atomically: true, encoding: .utf8
        )

        for result in results where gaps[result.name] == nil {
            for failure in result.hardFailures { XCTFail("\(result.name): \(failure)") }
        }
        if only != nil { return }
        try CompletionCorpusRunner.enforce(
            results: results,
            baseline: CompletionCorpusRunner.Baseline.load(from: Self.baselineURL),
            update: ProcessInfo.processInfo.environment["UPDATE_JAVA_NAVIGATION_BASELINE"] == "1",
            save: { try $0.save(to: Self.baselineURL) }
        )
    }

    // MARK: - Running one case

    private func run(_ corpusCase: CompletionCorpusRunner.Case, corpus: NavigationCorpusIndex) async -> CompletionCorpusRunner.Result {
        var result = CompletionCorpusRunner.Result(name: corpusCase.name)
        let text = corpusCase.text
        let position = CompletionCorpusRunner.position(in: text, utf16Offset: corpusCase.caretUTF16Offset)
        let document = Document(
            id: DocumentID(), url: corpusCase.url, displayName: corpusCase.url.lastPathComponent,
            contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: TextRange(start: position, end: position)), cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100), languageIdentifier: "java"
        )
        // Umbra keeps the open document's classes in the overlay (`JavaOverlayService`).
        let ownStubs = JavaSourceStubBuilder.build(source: text, url: corpusCase.url).classes
        await corpus.index.setOverlay(Dictionary(ownStubs.map { ($0.qualifiedName, $0) }, uniquingKeysWith: { first, _ in first }))
        let provider = JavaGoToDefinitionProvider(index: corpus.index, indexPaths: JavaIndexPaths(root: corpus.cacheRoot))
        let navigation = await provider.provide(context: NavigationContext(
            document: document, cursor: Cursor(position: position), selection: document.selection,
            trigger: .manual, kind: .definition
        ))
        Self.check(corpusCase, navigation: navigation, root: corpus.projectDirectory, into: &result)
        return result
    }

    private static func check(
        _ corpusCase: CompletionCorpusRunner.Case,
        navigation: NavigationResult?,
        root: URL,
        into result: inout CompletionCorpusRunner.Result
    ) {
        let directives = corpusCase.directives
        let locations: [Location]
        switch navigation {
        case nil: locations = []
        case .single(let location): locations = [location]
        case .multiple(let all): locations = all
        }

        if directives["none"] != nil {
            if !locations.isEmpty { result.hardFailures.append("expected nothing, got \(describe(locations))") }
            return
        }
        if let packageDirs = directives["package-dirs"] {
            checkPackageDirectories(CompletionCorpusRunner.list(packageDirs), locations: locations, into: &result)
            return
        }
        if let package = directives["package"] {
            checkPackage(package, locations: locations, into: &result)
            return
        }
        let wanted = directives["targets"].flatMap(Int.init) ?? 1
        if locations.count != wanted {
            result.hardFailures.append("\(locations.count) locations, expected \(wanted): \(describe(locations))")
        }
        guard let target = directives["target"] else {
            result.hardFailures.append("case states no expectation")
            return
        }
        let matches = locations.contains { location in matches(target, location: location, corpusCase: corpusCase) }
        if !matches {
            result.hardFailures.append("no location matches \(target): \(describe(locations))")
        }
    }

    private static func matches(_ target: String, location: Location, corpusCase: CompletionCorpusRunner.Case) -> Bool {
        guard let colon = target.lastIndex(of: ":") else { return false }
        let file = String(target[..<colon])
        let name = String(target[target.index(after: colon)...])
        let source: String
        if file == "self" {
            guard location.url == nil || sameFile(location.url, corpusCase.url) else { return false }
            source = corpusCase.text
        } else {
            guard let url = location.url, url.path.hasSuffix("/" + file),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            source = text
        }
        return selected(location, in: source) == name
    }

    private static func checkPackageDirectories(_ wanted: [String], locations: [Location], into result: inout CompletionCorpusRunner.Result) {
        let directories = locations.filter { $0.target == .directory }
        if directories.count != locations.count || locations.isEmpty {
            result.hardFailures.append("expected only folder locations, got \(describe(locations))")
            return
        }
        for suffix in wanted where !directories.contains(where: { $0.url?.path.hasSuffix("/" + suffix) == true }) {
            result.hardFailures.append("no folder ends with \(suffix): \(describe(locations))")
        }
        if directories.count != wanted.count {
            result.hardFailures.append("\(directories.count) folders, expected \(wanted.count): \(describe(locations))")
        }
    }

    private static func checkPackage(_ package: String, locations: [Location], into result: inout CompletionCorpusRunner.Result) {
        guard locations.count == 1, locations[0].target == .package(package) else {
            result.hardFailures.append("expected package \(package), got \(describe(locations))")
            return
        }
    }

    // MARK: - Helpers

    private static func sameFile(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }

    private static func selected(_ location: Location, in source: String) -> String {
        let ns = source as NSString
        let start = max(0, min(location.range.start.utf16Offset, ns.length))
        let end = max(start, min(location.range.end.utf16Offset, ns.length))
        return ns.substring(with: NSRange(location: start, length: end - start))
    }

    private static func describe(_ locations: [Location]) -> String {
        if locations.isEmpty { return "[]" }
        return "[" + locations.map { "\($0.url?.lastPathComponent ?? "self"):\($0.displayName)@\($0.range.start.utf16Offset)\($0.target == .source ? "" : " \($0.target)")" }.joined(separator: ", ") + "]"
    }

    private static func scorecard(results: [CompletionCorpusRunner.Result], gaps: [String: String]) -> String {
        let passing = results.filter(\.passes)
        let failing = results.filter { !$0.passes && gaps[$0.name] == nil }
        let knownGaps = results.filter { !$0.passes && gaps[$0.name] != nil }
        let fixedGaps = results.filter { $0.passes && gaps[$0.name] != nil }
        var lines = ["Java navigation corpus: \(passing.count)/\(results.count) pass, \(knownGaps.count) known gaps, \(failing.count) unexpected failures"]
        for result in fixedGaps { lines.append("  now passing, remove gap tag: \(result.name) (\(gaps[result.name] ?? ""))") }
        for result in failing { lines.append("  FAIL \(result.name): \(result.hardFailures.joined(separator: "; "))") }
        for result in knownGaps { lines.append("  gap  \(result.name) [\(gaps[result.name] ?? "")]: \(result.hardFailures.joined(separator: "; "))") }
        return lines.joined(separator: "\n")
    }

    private static var baselineURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/JavaNavigationCorpus/baseline.json")
    }
}

/// The shared index: the JDK's `ct.sym` plus the fixture project's sources, built once per run.
private struct NavigationCorpusIndex: Sendable {
    struct NoJDK: Error {}

    let index: JavaIndex
    let casesDirectory: URL
    let projectDirectory: URL
    let cacheRoot: URL

    static var directory: URL {
        guard let resourceURL = Bundle.module.resourceURL else { fatalError("PenumbraTests bundle has no resourceURL") }
        for candidate in [resourceURL.appendingPathComponent("JavaNavigationCorpus"), resourceURL.appendingPathComponent("Fixtures/JavaNavigationCorpus")]
            where FileManager.default.fileExists(atPath: candidate.appendingPathComponent("cases").path) {
            return candidate
        }
        fatalError("Could not locate JavaNavigationCorpus in test bundle at \(resourceURL)")
    }

    static func build() async throws -> NavigationCorpusIndex {
        guard let found = TestJDK.discovered, let installation = ReleaseFileParser.parse(found.home), installation.hasCtSym else {
            throw NoJDK()
        }
        let temporary = FileManager.default.temporaryDirectory
        let jdkShard = temporary.appendingPathComponent("nav-corpus-jdk-\(UUID().uuidString).idx")
        try JavaIndexShardWriter().write(try JDKCtSymRoot(installation: installation).readStubs(), stamp: JavaStamp(size: 0, modificationDate: 0), to: jdkShard)

        var projectStubs: [JavaClassStub] = []
        let projectDirectory = directory.appendingPathComponent("project")
        let enumerator = FileManager.default.enumerator(at: projectDirectory, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "java" else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            projectStubs += JavaSourceStubBuilder.build(source: source, url: url).classes
        }
        let projectShard = temporary.appendingPathComponent("nav-corpus-project-\(UUID().uuidString).idx")
        try JavaIndexShardWriter().write(projectStubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: projectShard)

        let index = JavaIndex()
        await index.setSources([
            .init(precedence: 1, reader: try JavaIndexShardReader(url: projectShard)),
            .init(precedence: 3, reader: try JavaIndexShardReader(url: jdkShard))
        ])
        let cacheRoot = temporary.appendingPathComponent("nav-corpus-cache-\(UUID().uuidString)", isDirectory: true)
        return NavigationCorpusIndex(
            index: index, casesDirectory: directory.appendingPathComponent("cases"),
            projectDirectory: projectDirectory, cacheRoot: cacheRoot
        )
    }
}
