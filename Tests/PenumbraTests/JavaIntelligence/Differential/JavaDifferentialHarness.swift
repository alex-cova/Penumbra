import EditorIntelligence
import Foundation
import XCTest
@testable import JavaIntelligence

/// Scores Umbra's completion, hover and definition against `javac` on projects that are not in
/// this repo. The checkouts live in the user caches directory at a pinned tag, so the in-repo
/// completion ratchet has nothing to fit.
///
/// The oracle is the analysis server's `attribute` request: `Trees.getElement` at the last
/// character of an identifier. Completion top-k recall is whether that symbol's name is among
/// the highest-ranked candidates once its first two characters are the prefix. Hover recall is
/// whether an explicit hover contains the name. Definition recall is whether go to definition
/// opens the declaration's file on a line inside it, and the wrong-symbol rate is how often an
/// answer lands somewhere else.
enum JavaDifferentialHarness {
    static let topK = 8
    static let prefixLength = 2
    static let defaultFilesPerProject = 6
    static let defaultPositionsPerFile = 12

    struct PinnedProject {
        var name: String
        var remote: String
        var tag: String
        /// Relative to the checkout root. Main sources only, so the sample is code the project ships.
        var sourceRoot: String
    }

    /// Real libraries, pinned to a release tag. `git clone --depth 1 --branch` resolves the tag
    /// to one commit, which the baseline records.
    static let pinnedProjects = [
        PinnedProject(
            name: "gson",
            remote: "https://github.com/google/gson.git",
            tag: "gson-parent-2.11.0",
            sourceRoot: "gson/src/main/java"
        ),
        PinnedProject(
            name: "jackson-core",
            remote: "https://github.com/FasterXML/jackson-core.git",
            tag: "jackson-core-2.17.2",
            sourceRoot: "src/main/java"
        ),
    ]

    struct IdentifierSite {
        var name: String
        var startUTF16: Int
        var endUTF16: Int
        var lastUTF16: Int { endUTF16 - 1 }
    }

    /// What one position contributed. `note` is the oracle and Umbra's answer, for a failing fixture.
    struct Verdict {
        var definitionScored = false
        var definitionMatched = false
        var definitionAnswered = false
        var completionScored = false
        var completionHit = false
        var hoverScored = false
        var hoverHit = false
        var note = ""
    }

    struct ProjectScore: Codable, Equatable {
        var name: String
        var tag: String
        var commit: String
        var files: Int
        var positions: Int
        var attributeFailures: Int
        var definitionScored: Int
        var definitionMatched: Int
        var definitionAnswered: Int
        var completionScored: Int
        var completionHit: Int
        var hoverScored: Int
        var hoverHit: Int

        var wrongSymbols: Int { definitionAnswered - definitionMatched }
    }

    struct Report: Codable, Equatable {
        var jdkFeature: Int
        var filesPerProject: Int
        var positionsPerFile: Int
        var topK: Int
        var prefixLength: Int
        var projects: [ProjectScore]

        static var baselineURL: URL {
            // #filePath is Tests/PenumbraTests/JavaIntelligence/Differential/<file>.
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/JavaDifferential/baseline.json")
        }

        static var documentURL: URL {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("docs/JAVA_DIFFERENTIAL.md")
        }

        static func load() -> Report? {
            guard let data = try? Data(contentsOf: baselineURL) else { return nil }
            return try? JSONDecoder().decode(Report.self, from: data)
        }

        func save() throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(self)
            try FileManager.default.createDirectory(at: Self.baselineURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: Self.baselineURL)
            try document.write(to: Self.documentURL, atomically: true, encoding: .utf8)
        }

        /// Empty when this run holds the baseline. A higher recall or a lower wrong-symbol count
        /// asks for a re-ratchet, the same way the parity corpus does.
        func differences(from baseline: Report) -> [String] {
            var lines: [String] = []
            if filesPerProject != baseline.filesPerProject || positionsPerFile != baseline.positionsPerFile
                || topK != baseline.topK || prefixLength != baseline.prefixLength {
                lines.append("sample shape changed: re-run with UPDATE_JAVA_DIFFERENTIAL=1")
            }
            for project in projects {
                guard let previous = baseline.projects.first(where: { $0.name == project.name }) else {
                    lines.append("NEW PROJECT \(project.name): re-run with UPDATE_JAVA_DIFFERENTIAL=1")
                    continue
                }
                if project.commit != previous.commit {
                    lines.append("\(project.name) commit \(previous.commit) is now \(project.commit)")
                }
                let sampleChanged = project.files != previous.files || project.positions != previous.positions
                    || project.definitionScored != previous.definitionScored
                    || project.completionScored != previous.completionScored
                    || project.hoverScored != previous.hoverScored
                if sampleChanged {
                    lines.append("\(project.name) scored a different sample (definition \(project.definitionScored) vs \(previous.definitionScored), completion \(project.completionScored) vs \(previous.completionScored)): re-run with UPDATE_JAVA_DIFFERENTIAL=1")
                    continue
                }
                lines += compare(project.name, "definition recall", project.definitionMatched, previous.definitionMatched, higherIsBetter: true)
                lines += compare(project.name, "wrong-symbol", project.wrongSymbols, previous.wrongSymbols, higherIsBetter: false)
                lines += compare(project.name, "completion top-\(topK)", project.completionHit, previous.completionHit, higherIsBetter: true)
                lines += compare(project.name, "hover", project.hoverHit, previous.hoverHit, higherIsBetter: true)
            }
            let missing = baseline.projects.map(\.name).filter { name in !projects.contains { $0.name == name } }
            for name in missing {
                lines.append("MISSING PROJECT \(name)")
            }
            return lines
        }

        var summary: String {
            projects.map { project in
                "\(project.name) \(project.commit.prefix(12)) definition \(format(project.definitionMatched, project.definitionScored)) wrong-symbol \(format(project.wrongSymbols, project.definitionAnswered)) completion \(format(project.completionHit, project.completionScored)) hover \(format(project.hoverHit, project.hoverScored))"
            }.joined(separator: "\n")
        }

        var document: String {
            var lines = [
                "# Java differential baseline",
                "",
                "Umbra's completion, hover and definition scored against `javac` on projects checked out",
                "at pinned tags, outside this repo (`~/Library/Caches/umbra-differential`). The completion",
                "corpus cannot be fitted to them.",
                "",
                "Regenerated by `UPDATE_JAVA_DIFFERENTIAL=1 JAVA_DIFFERENTIAL=1 swift test --filter testPinnedProjectsHoldTheBaseline`.",
                "Do not hand-edit the numbers. JDK under test: \(jdkFeature).",
                "",
                "An identifier of at least four characters is sampled at a fixed stride. The oracle attributes",
                "the file and resolves the symbol at its last character (`Trees.getElement`).",
                "",
                "- Definition recall: of the symbols declared in source, the share whose file Umbra opens on a line inside the declaration.",
                "- Wrong-symbol rate: of the positions Umbra answers, the share that land outside that declaration.",
                "- Completion top-\(topK): the symbol's name is among the \(topK) highest-ranked candidates when the prefix is its first \(prefixLength) characters.",
                "- Hover: an explicit hover contains the symbol's name.",
                "",
                "The same shape applies later to TypeScript (`tsserver`) and Swift (`sourcekit-lsp`).",
                "",
                "| project | commit | definition recall | wrong-symbol | completion top-\(topK) | hover |",
                "|---|---|---|---|---|---|",
            ]
            for project in projects {
                lines.append("| \(project.name) | `\(project.commit)` | \(format(project.definitionMatched, project.definitionScored)) | \(format(project.wrongSymbols, project.definitionAnswered)) | \(format(project.completionHit, project.completionScored)) | \(format(project.hoverHit, project.hoverScored)) |")
            }
            lines.append("")
            lines.append("Sample: \(filesPerProject) files per project, \(positionsPerFile) identifiers per file, stride-picked so one package cannot fill the run.")
            lines.append("")
            return lines.joined(separator: "\n")
        }
    }

    struct World: Sendable {
        var index: JavaIndex
        var cacheRoot: URL
        var jdkHome: URL
        var completion: JavaCompletionProvider
        var hover: JavaHoverProvider
        var openBuffer: @Sendable (URL) async -> String?
    }

    /// Clones the pinned projects, attributes a bounded sample, and scores Umbra against it.
    static func run() async throws -> Report {
        let environment = try ParityTestSupport.requireEnvironment()
        let client = JavaAnalysisServerClient(configuration: JavaAnalysisServerConfiguration(
            jarURL: environment.jarURL,
            javaExecutable: environment.jdk.home.appendingPathComponent("bin/java"),
            maxHeapMB: 2048
        ), idleTimeout: .seconds(600))
        do {
            let report = try await scorePinned(environment: environment, client: client)
            await client.shutdown()
            return report
        } catch {
            await client.shutdown()
            throw error
        }
    }

    static func scorePinned(environment: ParityTestSupport.Environment, client: JavaAnalysisServerClient) async throws -> Report {
        let filesPerProject = intEnv("JAVA_DIFFERENTIAL_FILES", default: defaultFilesPerProject)
        let positionsPerFile = intEnv("JAVA_DIFFERENTIAL_POSITIONS", default: defaultPositionsPerFile)
        let jdkShard = try writeJDKShard(installation: environment.jdk)
        var projects: [ProjectScore] = []
        for pinned in pinnedProjects {
            let checkout = try checkout(pinned)
            let sourceRoot = checkout.sourceRoot.resolvingSymlinksInPath()
            try await client.configure(JavaAnalysisServerModule(moduleId: pinned.name, sourcepath: [sourceRoot]))
            let world = try await makeWorld(sourceRoot: sourceRoot, jdkShard: jdkShard, installation: environment.jdk)
            let score = await score(
                name: pinned.name, tag: pinned.tag, commit: checkout.commit,
                sourceRoot: sourceRoot, moduleId: pinned.name, client: client, world: world,
                filesPerProject: filesPerProject, positionsPerFile: positionsPerFile
            )
            projects.append(score)
            print("differential \(score.name) \(format(score.definitionMatched, score.definitionScored)) definition, \(format(score.completionHit, score.completionScored)) completion")
        }
        return Report(
            jdkFeature: environment.jdk.featureVersion,
            filesPerProject: filesPerProject,
            positionsPerFile: positionsPerFile,
            topK: topK,
            prefixLength: prefixLength,
            projects: projects
        )
    }

    /// One project directory. `commit` is recorded as-is (a fixture passes a label).
    static func score(
        name: String, tag: String, commit: String, sourceRoot: URL, moduleId: String,
        client: JavaAnalysisServerClient, world: World, filesPerProject: Int, positionsPerFile: Int
    ) async -> ProjectScore {
        let files = javaFiles(under: sourceRoot, limit: filesPerProject)
        var score = ProjectScore(
            name: name, tag: tag, commit: commit, files: files.count, positions: 0,
            attributeFailures: 0, definitionScored: 0, definitionMatched: 0, definitionAnswered: 0,
            completionScored: 0, completionHit: 0, hoverScored: 0, hoverHit: 0
        )
        for file in files {
            let resolved = file.resolvingSymlinksInPath()
            guard let text = try? String(contentsOf: resolved, encoding: .utf8), text.utf16.count < 400_000 else { continue }
            let sites = identifierSites(in: text, limit: positionsPerFile)
            guard !sites.isEmpty else { continue }
            let symbols: [JavaAnalysisSymbol]
            do {
                symbols = try await client.attribute(
                    moduleId: moduleId, file: resolved, text: text, positions: sites.map(\.lastUTF16)
                )
            } catch {
                score.attributeFailures += 1
                print("differential \(name) \(resolved.lastPathComponent) attribute failed: \(error)")
                continue
            }
            let byPosition = Dictionary(symbols.map { ($0.position, $0) }, uniquingKeysWith: { first, _ in first })
            score.positions += sites.count
            for site in sites {
                guard let symbol = byPosition[site.lastUTF16] else { continue }
                let verdict = await self.verdict(site: site, symbol: symbol, text: text, file: resolved, world: world)
                if verdict.definitionScored {
                    score.definitionScored += 1
                    if verdict.definitionMatched { score.definitionMatched += 1 }
                    if verdict.definitionAnswered { score.definitionAnswered += 1 }
                }
                if verdict.completionScored {
                    score.completionScored += 1
                    if verdict.completionHit { score.completionHit += 1 }
                }
                if verdict.hoverScored {
                    score.hoverScored += 1
                    if verdict.hoverHit { score.hoverHit += 1 }
                }
            }
        }
        return score
    }

    static func verdict(site: IdentifierSite, symbol: JavaAnalysisSymbol, text: String, file: URL, world: World) async -> Verdict {
        var verdict = Verdict()
        let prefix = String(site.name.prefix(prefixLength))
        if symbol.hasSourceDeclaration,
           let declarationFile = symbol.declarationFile,
           let startLine = symbol.declarationStartLine,
           let endLine = symbol.declarationEndLine {
            verdict.definitionScored = true
            let hits = await JavaGoToDefinition.resolve(
                source: text, fileURL: file, utf16Offset: site.lastUTF16, index: world.index,
                jdkHome: world.jdkHome, cacheRoot: world.cacheRoot, openBuffer: world.openBuffer,
                decompile: JavaDecompileGate(policy: .denied)
            )
            verdict.definitionAnswered = hits.contains { $0.url != nil }
            verdict.definitionMatched = hits.contains { hit in
                guard let url = hit.url else { return false }
                let line = hit.range.start.line + 1
                return sameFile(url.path, declarationFile) && line >= startLine && line <= endLine
            }
            let renderedHits = hits.map { hit -> String in
                let path = hit.url?.lastPathComponent ?? "nil"
                return "\(path):\(hit.range.start.line + 1)"
            }.joined(separator: ", ")
            verdict.note = "definition [\(renderedHits)] oracle \(URL(fileURLWithPath: declarationFile).lastPathComponent):\(startLine)-\(endLine)"
        }
        guard site.name.hasPrefix(prefix), symbol.name.count >= prefixLength else { return verdict }
        verdict.completionScored = true
        verdict.hoverScored = true

        let caret = position(in: text, utf16: site.startUTF16 + min(prefixLength, site.name.utf16.count))
        let prefixStart = position(in: text, utf16: site.startUTF16)
        let completing = document(url: file, text: text, caret: caret)
        let items = await world.completion.provide(context: CompletionContext(
            document: completing,
            cursor: Cursor(position: caret),
            trigger: .manual,
            prefix: prefix,
            range: TextRange(start: prefixStart, end: caret)
        ))
        let labels = items.prefix(topK).map(\.label)
        verdict.completionHit = labels.contains { $0 == symbol.name || $0.hasPrefix(symbol.name + "(") }

        let hoverCaret = position(in: text, utf16: site.lastUTF16)
        let hovering = document(url: file, text: text, caret: hoverCaret)
        let hover = await world.hover.provide(context: HoverContext(
            document: hovering, cursor: Cursor(position: hoverCaret),
            selection: Selection(range: TextRange(start: hoverCaret, end: hoverCaret)),
            trigger: .manual
        ))
        verdict.hoverHit = hover?.contents.contains(symbol.name) == true
        verdict.note += " completion [\(labels.joined(separator: ", "))] hover \(hover?.contents.contains(symbol.name) == true ? "yes" : "no")"
        return verdict
    }

    static func makeWorld(sourceRoot: URL, jdkShard: URL, installation: JDKInstallation) async throws -> World {
        var stubs: [JavaClassStub] = []
        for file in javaFiles(under: sourceRoot, limit: Int.max) {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            stubs.append(contentsOf: JavaSourceStubBuilder.build(source: source, url: file).classes)
        }
        let temporary = FileManager.default.temporaryDirectory
        let projectShard = temporary.appendingPathComponent("differential-project-\(UUID().uuidString).idx")
        try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: projectShard)
        let index = JavaIndex()
        await index.setSources([
            .init(precedence: 1, reader: try JavaIndexShardReader(url: projectShard)),
            .init(precedence: 3, reader: try JavaIndexShardReader(url: jdkShard)),
        ])
        let cacheRoot = temporary.appendingPathComponent("differential-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let hover = JavaHoverProvider(index: index, indexPaths: JavaIndexPaths(root: cacheRoot))
        await hover.setJDKHome(installation.home)
        let openBuffer: @Sendable (URL) async -> String? = { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }
        return World(
            index: index, cacheRoot: cacheRoot, jdkHome: installation.home,
            completion: JavaCompletionProvider(index: index), hover: hover, openBuffer: openBuffer
        )
    }

    static func writeJDKShard(installation: JDKInstallation) throws -> URL {
        let shard = FileManager.default.temporaryDirectory.appendingPathComponent("differential-jdk-\(UUID().uuidString).idx")
        try JavaIndexShardWriter().write(
            try JDKCtSymRoot(installation: installation).readStubs(),
            stamp: JavaStamp(size: 0, modificationDate: 0), to: shard
        )
        return shard
    }

    // MARK: - Sampling

    /// Identifiers of at least four characters, outside comments and keywords, spread across the file.
    static func identifierSites(in text: String, limit: Int) -> [IdentifierSite] {
        let ns = text as NSString
        guard let expression = try? NSRegularExpression(pattern: #"\b[A-Za-z_$][A-Za-z0-9_$]{3,}\b"#) else { return [] }
        var sites: [IdentifierSite] = []
        expression.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            let name = ns.substring(with: match.range)
            guard !keywords.contains(name), !isInComment(ns, range: match.range) else { return }
            sites.append(IdentifierSite(name: name, startUTF16: match.range.location, endUTF16: NSMaxRange(match.range)))
        }
        return strideSample(sites, count: limit)
    }

    static func javaFiles(under root: URL, limit: Int) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var files: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "java" else { continue }
            let name = url.lastPathComponent
            if name == "package-info.java" || name == "module-info.java" { continue }
            files.append(url)
        }
        files.sort { $0.path < $1.path }
        return strideSample(files, count: limit)
    }

    // MARK: - Checkout

    struct Checkout {
        var sourceRoot: URL
        var commit: String
    }

    static func checkout(_ project: PinnedProject) throws -> Checkout {
        let root = try cachesRoot().appendingPathComponent("\(project.name)-\(project.tag)", isDirectory: true)
        if !FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) {
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
            try runGit(["clone", "--quiet", "--depth", "1", "--branch", project.tag, project.remote, root.path])
        }
        let commit = try runGit(["-C", root.path, "rev-parse", "HEAD"])
        let source = root.appendingPathComponent(project.sourceRoot)
        guard FileManager.default.fileExists(atPath: source.path) else {
            let top = (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.sorted().joined(separator: ", ") ?? ""
            throw DifferentialError.sourceRootMissing("\(source.path) (checkout contains: \(top))")
        }
        return Checkout(sourceRoot: source, commit: commit)
    }

    static func cachesRoot() throws -> URL {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = caches.appendingPathComponent("umbra-differential", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    static func runGit(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("differential-git-\(UUID().uuidString).out")
        let errURL = FileManager.default.temporaryDirectory.appendingPathComponent("differential-git-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: outURL)
        let stderr = try FileHandle(forWritingTo: errURL)
        process.standardOutput = stdout
        process.standardError = stderr
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        try stdout.close()
        try stderr.close()
        let errText = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        let outText = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: outURL)
        try? FileManager.default.removeItem(at: errURL)
        guard process.terminationStatus == 0 else {
            throw DifferentialError.git("git \(arguments.joined(separator: " ")): \(errText)")
        }
        return outText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Text

    static func document(url: URL, text: String, caret: TextPosition) -> Document {
        Document(
            id: DocumentID(), url: url, displayName: url.lastPathComponent,
            contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: TextRange(start: caret, end: caret)),
            cursor: Cursor(position: caret),
            viewport: Viewport(x: 0, y: 0, width: 800, height: 600),
            languageIdentifier: "java"
        )
    }

    static func position(in text: String, utf16: Int) -> TextPosition {
        let ns = text as NSString
        let bounded = min(max(0, utf16), ns.length)
        let prefix = ns.substring(to: bounded) as NSString
        var line = 0
        var lastBreak = -1
        for index in 0..<prefix.length {
            if prefix.character(at: index) == 0x0A {
                line += 1
                lastBreak = index
            }
        }
        let column = lastBreak < 0 ? bounded : bounded - lastBreak - 1
        return TextPosition(line: line, column: column, utf16Offset: bounded)
    }

    static func sameFile(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: lhs).resolvingSymlinksInPath().path == URL(fileURLWithPath: rhs).resolvingSymlinksInPath().path
    }

    static func strideSample<T>(_ items: [T], count: Int) -> [T] {
        guard count > 0 else { return [] }
        guard items.count > count else { return items }
        return (0..<count).map { items[$0 * items.count / count] }
    }

    static func intEnv(_ name: String, default defaultValue: Int) -> Int {
        guard let raw = ProcessInfo.processInfo.environment[name], let value = Int(raw), value > 0 else { return defaultValue }
        return value
    }

    static func format(_ hit: Int, _ total: Int) -> String {
        guard total > 0 else { return "n/a" }
        let tenths = 1000 * hit / total
        return "\(tenths / 10).\(tenths % 10)% (\(hit)/\(total))"
    }

    static func compare(_ project: String, _ label: String, _ value: Int, _ baseline: Int, higherIsBetter: Bool) -> [String] {
        if value == baseline { return [] }
        let improved = higherIsBetter ? value > baseline : value < baseline
        if improved {
            return ["IMPROVED \(project) \(label) \(baseline) -> \(value): re-run with UPDATE_JAVA_DIFFERENTIAL=1"]
        }
        return ["\(project) \(label) regressed \(baseline) -> \(value)"]
    }

    static func isInComment(_ text: NSString, range: NSRange) -> Bool {
        let lineRange = text.lineRange(for: NSRange(location: range.location, length: 0))
        let line = text.substring(with: lineRange)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { return true }
        let column = range.location - lineRange.location
        let head = (line as NSString).substring(to: min(max(0, column), (line as NSString).length))
        guard let slashes = head.range(of: "//") else { return false }
        let quotes = head[..<slashes.lowerBound].filter { $0 == "\"" }.count
        return quotes.isMultiple(of: 2)
    }

    static let keywords: Set<String> = [
        "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const",
        "continue", "default", "do", "double", "else", "enum", "extends", "final", "finally", "float",
        "for", "goto", "if", "implements", "import", "instanceof", "int", "interface", "long", "native",
        "new", "package", "private", "protected", "public", "return", "short", "static", "strictfp",
        "super", "switch", "synchronized", "this", "throw", "throws", "transient", "true", "false",
        "try", "void", "volatile", "while", "var", "yield", "record", "sealed", "permits", "null",
    ]
}

enum DifferentialError: Error, CustomStringConvertible {
    case git(String)
    case sourceRootMissing(String)

    var description: String {
        switch self {
        case .git(let message): return message
        case .sourceRootMissing(let path): return "source root missing: \(path)"
        }
    }
}
