import EditorIntelligence
import Foundation
import XCTest
@testable import JavaIntelligence

/// Real-project completion quality, by completion context. See `docs/JAVA_COMPLETION_QUALITY.md`.
///
/// **Oracle.** The expected candidate at a site is what the developer wrote there (an *observed
/// choice*), kept only where `javac` (`Trees.getElement`) resolves that identifier to a symbol of
/// the same name, so the choice is also compiler-valid. A different candidate in the list is not
/// necessarily wrong: recall is therefore a lower bound on usefulness, and the separate
/// *invalid-candidate rate* asks `javac` whether the other top candidates are valid at all.
///
/// **Sampling.** Files and sites are stride-sampled (deterministic), declarations are skipped, the
/// typed prefix is the first `prefixLength` characters and the identifier's tail is removed, the way
/// typing produces the buffer. `broken-line` additionally removes the rest of the line, so the
/// statement is left unterminated and its parentheses unbalanced, as while typing.
///
/// **Insertion.** The top three candidates are applied the way the editor applies them
/// (`CompletionInsertion`, additional edits) and the result is parsed: a candidate whose insertion
/// introduces a syntax error into a file that parsed cleanly is an incorrect insertion.
enum JavaCompletionQualityHarness {
    static let contexts = [
        "local", "field", "method", "static", "chain", "constructor", "import", "generic", "lambda", "type", "other",
    ]

    struct Accumulator: Codable {
        var sites = 0
        var recall1 = 0
        var recall3 = 0
        var recall8 = 0
        var reciprocalRank = 0.0
        var empty = 0
        var absent = 0
        var top8Slots = 0
        var top8Duplicates = 0
        var insertionChecked = 0
        var insertionBad = 0
        var insertionExact = 0
        var controlsChecked = 0
        var controlsDetected = 0
        var candidatesChecked = 0
        var candidatesInvalid = 0
        var validitySites = 0
    }

    struct Report: Codable {
        var prefixLength: Int
        var jdkFeature: Int
        /// "variant/context" → numbers.
        var cells: [String: Accumulator] = [:]
        var projects: [String] = []
        var misses: [String] = []
        var invalidSamples: [String] = []
        var insertionSamples: [String] = []
        var rankSamples: [String] = []
        /// Sites left out of scoring, by reason (every sampled site is accounted for).
        var exclusions: [String: Int] = [:]
        var sitesSampled = 0
        /// Why a negative control could not be used, by reason.
        var controlReasons: [String: Int] = [:]
        var filesSampled = 0
        var filesCleanCompile = 0
        var baselineErrorKeys: [String: Int] = [:]
    }

    /// What javac says about a file as it is on disk: the ground the controls are judged against.
    struct FileBaseline {
        var errors = 0
        /// End offsets of "cannot name this member" errors javac already reports in the file as it is.
        var invalidEnds = Set<Int>()
        var setupFailure = false
        var checkFailed = false
    }

    static func intEnv(_ name: String, _ fallback: Int) -> Int {
        ProcessInfo.processInfo.environment[name].flatMap(Int.init) ?? fallback
    }

    // MARK: - Projects

    /// A source tree scored as a unit. `group` keeps development projects (inspected while the fixes
    /// were written) apart from held-out ones in every table.
    struct QualityProject {
        var name: String
        var group: String
        var sourceRoots: [URL]
        /// Extra javac source path (generated sources), not sampled.
        var extraSourcepath: [URL] = []
        var classpath: [URL] = []
        var processorPath: [URL] = []
        var model: JavaGradleProjectModel?
        var note = ""
    }

    struct ProjectResult {
        var project: QualityProject
        var report: Report
    }

    /// `module-info.java` makes javac refuse a source path whose `requires` it cannot find
    /// (`module.not.found`) before it attributes anything, which blinds the negative control. The
    /// copy without it is what the oracle compiles; completion sees the same files.
    static func withoutModuleInfo(_ root: URL, name: String) throws -> (url: URL, note: String) {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("module-info.java").path) else { return (root, "") }
        let mirror = FileManager.default.temporaryDirectory.appendingPathComponent("quality-mirror-\(name)", isDirectory: true)
        try? FileManager.default.removeItem(at: mirror)
        try FileManager.default.copyItem(at: root, to: mirror)
        try FileManager.default.removeItem(at: mirror.appendingPathComponent("module-info.java"))
        return (mirror.resolvingSymlinksInPath(), "module-info.java removed for the compile oracle")
    }

    static func publicProject(
        name: String, remote: String, tag: String, sourceRoot: String, group: String
    ) throws -> QualityProject {
        let checkout = try JavaDifferentialHarness.checkout(.init(name: name, remote: remote, tag: tag, sourceRoot: sourceRoot))
        let mirrored = try withoutModuleInfo(checkout.sourceRoot.resolvingSymlinksInPath(), name: name)
        return QualityProject(name: name, group: group, sourceRoots: [mirrored.url], note: mirrored.note)
    }

    static func developmentProjects() throws -> [QualityProject] {
        try JavaDifferentialHarness.pinnedProjects.map {
            try publicProject(name: $0.name, remote: $0.remote, tag: $0.tag, sourceRoot: $0.sourceRoot, group: "development")
        }
    }

    /// Projects nothing in the fixes was written against: two public libraries with heavy generics
    /// and deep hierarchies, and the Gradle projects Umbra has synced (their cached models give the
    /// source sets, the jars and the processor path). `JAVA_QUALITY_GRADLE=a,b` picks models by
    /// project directory name.
    static func heldOutProjects() throws -> [QualityProject] {
        var projects = [
            try publicProject(
                name: "commons-collections", remote: "https://github.com/apache/commons-collections.git",
                tag: "rel/commons-collections-4.5.0", sourceRoot: "src/main/java", group: "held-out"
            ),
            try publicProject(
                name: "jOOL", remote: "https://github.com/jOOQ/jOOL.git",
                tag: "version-0.9.15", sourceRoot: "jOOL-java-8/src/main/java", group: "held-out"
            ),
        ]
        projects += gradleProjects()
        return projects
    }

    static func gradleProjects() -> [QualityProject] {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.umbra.editor/gradle-models")
        let wanted = ProcessInfo.processInfo.environment["JAVA_QUALITY_GRADLE"].map { Set($0.split(separator: ",").map(String.init)) }
        var result: [QualityProject] = []
        let entries = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.path < $1.path }
        for entry in entries {
            guard let data = try? Data(contentsOf: entry.appendingPathComponent("model.json")),
                  let model = try? JSONDecoder().decode(JavaGradleProjectModel.self, from: data),
                  let root = model.subprojects.first(where: { $0.path == ":" }) ?? model.subprojects.first else { continue }
            let name = root.directory.lastPathComponent
            if let wanted, !wanted.contains(name) { continue }
            let mains = model.subprojects.flatMap { $0.sourceSets.filter { $0.name == "main" } }
            let exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
            let roots = mains.flatMap(\.sourceDirs).filter(exists).map { $0.resolvingSymlinksInPath() }
            guard !roots.isEmpty else { continue }
            var seen = Set<String>()
            let processors = mains.flatMap(\.annotationProcessorJars).filter { exists($0) && seen.insert($0.path).inserted }
            result.append(QualityProject(
                name: name, group: "held-out", sourceRoots: roots,
                extraSourcepath: mains.flatMap(\.generatedSourceDirs).filter(exists),
                classpath: model.classpathJars.filter(exists), processorPath: processors, model: model,
                note: "Gradle model: \(model.subprojects.count) subprojects, \(model.classpathJars.count) jars"
            ))
        }
        return result
    }

    /// The same index Umbra builds for a synced project: project source shards, dependency jar
    /// shards, the JDK, with completion scoped to the file's source set.
    static func makeModelWorld(
        _ model: JavaGradleProjectModel, jdkShard: URL, installation: JDKInstallation
    ) async throws -> JavaDifferentialHarness.World {
        let temporary = FileManager.default.temporaryDirectory
        let cacheRoot = temporary.appendingPathComponent("quality-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let paths = JavaIndexPaths(root: cacheRoot)
        let sourceTargets = model.sourceIndexTargets(paths: paths)
        let jarTargets = model.jarIndexTargets(paths: paths)
        for await _ in await JavaIndexScheduler(paths: paths).index(sourceTargets + jarTargets) {}
        var sources: [JavaIndex.Source] = []
        for target in sourceTargets {
            if let reader = try? JavaIndexShardReader(url: target.shardURL) {
                sources.append(.init(precedence: 1, reader: reader, shardPath: target.shardURL.path))
            }
        }
        for target in jarTargets {
            if let reader = try? JavaIndexShardReader(url: target.shardURL) {
                sources.append(.init(precedence: 2, reader: reader, shardPath: target.shardURL.path))
            }
        }
        sources.append(.init(precedence: 3, reader: try JavaIndexShardReader(url: jdkShard)))
        let index = JavaIndex()
        await index.setSources(sources)
        let provider = JavaCompletionProvider(index: index)
        await provider.setSourceSetClasspath(model, indexPaths: paths)
        let hover = JavaHoverProvider(index: index, indexPaths: paths)
        await hover.setJDKHome(installation.home)
        let openBuffer: @Sendable (URL) async -> String? = { url in try? String(contentsOf: url, encoding: .utf8) }
        return JavaDifferentialHarness.World(
            index: index, cacheRoot: cacheRoot, jdkHome: installation.home,
            completion: provider, hover: hover, openBuffer: openBuffer
        )
    }

    static func run(set: String) async throws -> [ProjectResult] {
        let environment = try ParityTestSupport.requireEnvironment()
        let client = JavaAnalysisServerClient(configuration: JavaAnalysisServerConfiguration(
            jarURL: environment.jarURL,
            javaExecutable: environment.jdk.home.appendingPathComponent("bin/java"),
            maxHeapMB: 4096
        ), idleTimeout: .seconds(1800))
        let prefixLength = intEnv("JAVA_QUALITY_PREFIX", 1)
        let jdkShard = try JavaDifferentialHarness.writeJDKShard(installation: environment.jdk)
        var projects: [QualityProject] = []
        if set == "development" || set == "all" { projects += try developmentProjects() }
        if set == "held-out" || set == "all" { projects += try heldOutProjects() }
        var results: [ProjectResult] = []
        do {
            for project in projects {
                var report = Report(prefixLength: prefixLength, jdkFeature: environment.jdk.featureVersion)
                report.projects = [project.name]
                try await client.configure(JavaAnalysisServerModule(
                    moduleId: project.name, classpath: project.classpath,
                    sourcepath: project.sourceRoots + project.extraSourcepath, processorPath: project.processorPath
                ))
                let world: JavaDifferentialHarness.World
                if let model = project.model {
                    world = try await makeModelWorld(model, jdkShard: jdkShard, installation: environment.jdk)
                } else {
                    world = try await JavaDifferentialHarness.makeWorld(
                        sourceRoot: project.sourceRoots[0], jdkShard: jdkShard, installation: environment.jdk
                    )
                }
                if ProcessInfo.processInfo.environment["JAVA_QUALITY_STATS"] == "1" {
                    // What Umbra's name index gives the provider in the app: files mentioning a name.
                    await world.completion.setUsageStatistics(ProjectWordCounts(roots: project.sourceRoots))
                }
                await score(project: project, client: client, world: world, into: &report)
                results.append(ProjectResult(project: project, report: report))
            }
            await client.shutdown()
        } catch {
            await client.shutdown()
            throw error
        }
        return results
    }

    // MARK: - Scoring

    static func exclude(_ reason: String, _ report: inout Report) {
        report.exclusions[reason, default: 0] += 1
    }

    static func score(
        project: QualityProject, client: JavaAnalysisServerClient,
        world: JavaDifferentialHarness.World, into report: inout Report
    ) async {
        let name = project.name
        var candidates: [URL] = []
        for root in project.sourceRoots { candidates += JavaDifferentialHarness.javaFiles(under: root, limit: Int.max) }
        candidates = Array(Set(candidates)).sorted { $0.path < $1.path }
        let files = JavaDifferentialHarness.strideSample(candidates, count: intEnv("JAVA_QUALITY_FILES", 30))
        let perFile = intEnv("JAVA_QUALITY_POSITIONS", 60)
        let validityBudget = intEnv("JAVA_QUALITY_VALIDITY_SITES", 120)
        var validityUsed = 0
        let prefixLength = report.prefixLength
        for file in files {
            report.filesSampled += 1
            let resolved = file.resolvingSymlinksInPath()
            guard let text = try? String(contentsOf: resolved, encoding: .utf8), text.utf16.count < 300_000 else {
                exclude("file: unreadable or over 300k UTF-16 units", &report); continue
            }
            guard let tree = JavaSyntaxParser().parse(text), !tree.rootNode.hasError else {
                exclude("file: tree-sitter syntax error (whole file skipped)", &report); continue
            }
            let sites = JavaDifferentialHarness.identifierSites(in: text, limit: perFile).sites
            report.sitesSampled += sites.count
            guard !sites.isEmpty else { continue }
            guard let symbols = try? await client.attribute(
                moduleId: name, file: resolved, text: text, positions: sites.map(\.lastUTF16)
            ) else {
                for _ in sites { exclude("oracle: attribute request failed", &report) }
                continue
            }
            let byPosition = Dictionary(symbols.map { ($0.position, $0) }, uniquingKeysWith: { first, _ in first })
            let (roles, _) = JavaDifferentialHarness.siteMaps(in: text)
            // The file as it stands, compiled: its errors say whether the oracle can be trusted here.
            var baseline = FileBaseline()
            if let diagnostics = try? await client.check(moduleId: name, file: resolved, text: text) {
                let errors = diagnostics.filter { $0.severity == .error }
                baseline.errors = errors.count
                baseline.invalidEnds = Set(errors.filter { isInvalidKey($0.key) }.compactMap(\.end))
                baseline.setupFailure = errors.contains {
                    $0.key.contains("module.not.found") || $0.key.contains("cant.access") || $0.key.contains("doesnt.exist")
                }
                for error in errors { report.baselineErrorKeys[error.key, default: 0] += 1 }
            } else {
                baseline.checkFailed = true
                report.baselineErrorKeys["(check failed)", default: 0] += 1
            }
            let cleanFile = !baseline.checkFailed && baseline.errors == 0
            if cleanFile { report.filesCleanCompile += 1 }
            for site in sites {
                guard let symbol = byPosition[site.lastUTF16] else { exclude("oracle: javac resolved no symbol at the site", &report); continue }
                guard symbol.name == site.name else { exclude("oracle: resolved symbol has another name", &report); continue }
                guard symbol.kind != "package" else { exclude("site: package segment", &report); continue }
                guard roles[site.startUTF16] != .declared else { exclude("site: declaration name", &report); continue }
                guard site.name.utf16.count > prefixLength else { exclude("site: name not longer than the prefix", &report); continue }
                if isDeclarationName(site: site, text: text, tree: tree) { exclude("site: declaration name (role map missed it)", &report); continue }
                let context = classify(site: site, symbol: symbol, role: roles[site.startUTF16], text: text, tree: tree)
                for variant in ["complete", "broken-line"] {
                    let wantsValidity = variant == "complete" && validityUsed < validityBudget
                        && (context == "method" || context == "chain" || context == "static" || context == "field")
                        && JavaDifferentialHarness.isDotted(at: site.startUTF16, in: text)
                    if wantsValidity { validityUsed += 1 }
                    let delta = await scoreSite(
                        variant: variant, context: context, site: site, text: text, file: resolved,
                        projectName: name, client: client, world: world, prefixLength: prefixLength,
                        checkValidity: wantsValidity, baseline: baseline, symbolKind: symbol.kind,
                        fileLabel: resolved.lastPathComponent, into: &report
                    )
                    report.cells["\(variant)/\(context)", default: Accumulator()] = merged(report.cells["\(variant)/\(context)"] ?? Accumulator(), delta)
                    if cleanFile {
                        report.cells["\(variant)-clean/\(context)", default: Accumulator()] = merged(report.cells["\(variant)-clean/\(context)"] ?? Accumulator(), delta)
                    }
                }
            }
        }
    }

    static func scoreSite(
        variant: String, context: String, site: JavaDifferentialHarness.IdentifierSite, text: String,
        file: URL, projectName: String, client: JavaAnalysisServerClient, world: JavaDifferentialHarness.World,
        prefixLength: Int, checkValidity: Bool, baseline: FileBaseline, symbolKind: String, fileLabel: String, into report: inout Report
    ) async -> Accumulator {
        let prefix = String(site.name.prefix(prefixLength))
        let ns = text as NSString
        let caretOffset = site.startUTF16 + prefixLength
        var buffer = ns.substring(to: caretOffset)
        var rest = ns.substring(from: site.endUTF16)
        if variant == "broken-line" {
            if let newline = rest.firstIndex(of: "\n") { rest = String(rest[newline...]) } else { rest = "" }
        }
        buffer += rest
        let caret = JavaDifferentialHarness.position(in: buffer, utf16: caretOffset)
        let prefixStart = JavaDifferentialHarness.position(in: buffer, utf16: site.startUTF16)
        let items = await world.completion.provide(context: CompletionContext(
            document: JavaDifferentialHarness.document(url: file, text: buffer, caret: caret),
            cursor: Cursor(position: caret),
            trigger: .keystroke(String(prefix.suffix(1))),
            prefix: prefix,
            range: EditorIntelligence.TextRange(start: prefixStart, end: caret)
        ))
        let ranked = DefaultRanker(recency: CompletionRecency()).rankSynchronously(items: items, prefix: prefix)
        let rank = ranked.firstIndex { $0.item.label == site.name || $0.item.label.hasPrefix(site.name + "(") }.map { $0 + 1 }

        if let debug = ProcessInfo.processInfo.environment["JAVA_QUALITY_DEBUG"], variant == "complete",
           debug == "\(fileLabel):\(site.startUTF16)" {
            let line = ns.substring(with: ns.lineRange(for: NSRange(location: site.startUTF16, length: 0)))
            print("QUALITY-DEBUG \(debug) context=\(context) rank=\(rank.map(String.init) ?? "nil") items=\(items.count)\nline: \(line)")
            print("  raw has expected: \(items.contains { $0.label == site.name }) ranked count \(ranked.count) java.lang: \(items.filter { $0.labelDetail?.contains("java.lang") == true }.map(\.label).sorted().joined(separator: ","))")
            for (index, entry) in ranked.prefix(25).enumerated() {
                print("  \(index + 1). \(entry.item.label) \(entry.item.labelDetail ?? "") [\(entry.item.kind)] prio=\(entry.item.priority) detail=\(entry.item.detail ?? "")")
            }
        }
        var cell = Accumulator()
        cell.sites += 1
        if items.isEmpty { cell.empty += 1 }
        if let rank {
            if rank <= 1 { cell.recall1 += 1 }
            if rank <= 3 { cell.recall3 += 1 }
            if rank <= 8 { cell.recall8 += 1 }
            cell.reciprocalRank += 1.0 / Double(rank)
        } else {
            cell.absent += 1
            if report.misses.count < 60 {
                report.misses.append("\(variant) \(context) \(projectName)/\(fileLabel) `\(site.name)` @\(site.startUTF16) top: \(ranked.prefix(5).map(\.item.label).joined(separator: ", "))")
            }
        }
        if variant == "complete", let rank, rank > 1, rank <= 8,
           report.rankSamples.filter({ $0.hasPrefix(context + " ") }).count < 14 {
            let line = ns.substring(with: ns.lineRange(for: NSRange(location: site.startUTF16, length: 0))).trimmingCharacters(in: .whitespacesAndNewlines)
            report.rankSamples.append("\(context) rank \(rank) `\(site.name)` (typed `\(prefix)`) over [\(ranked.prefix(rank - 1).map { "\($0.item.label)\($0.item.detail.map { ":" + $0 } ?? "")" }.joined(separator: ", "))] in `\(line.prefix(110))`")
        }
        var seen = Set<String>()
        for entry in ranked.prefix(8) {
            cell.top8Slots += 1
            let signature = "\(entry.item.label)|\(entry.item.labelDetail ?? "")|\(entry.item.detail ?? "")|\(entry.item.kind)"
            if !seen.insert(signature).inserted { cell.top8Duplicates += 1 }
        }

        if variant == "complete", let truth = ranked.first(where: {
            $0.item.label == site.name || $0.item.label.hasPrefix(site.name + "(")
        })?.item {
            // The candidate the developer chose, accepted the way the editor does. The file the
            // site came from parses cleanly, so a syntax error after the insertion is the
            // insertion's. Exact: the result is the original text (arguments the developer typed
            // stay where they are).
            cell.insertionChecked += 1
            let applied = apply(truth, to: buffer)
            if JavaSyntaxParser().parse(applied)?.rootNode.hasError ?? true {
                cell.insertionBad += 1
                if report.insertionSamples.count < 40 {
                    report.insertionSamples.append("\(context) `\(truth.label)` insertText=\(truth.insertText.debugDescription) next=\(nextCharacter(in: buffer, at: truth.range).debugDescription) in \(fileLabel)@\(site.startUTF16): \((applied as NSString).substring(with: NSRange(location: max(0, site.startUTF16 - 12), length: min(48, (applied as NSString).length - max(0, site.startUTF16 - 12)))).debugDescription)")
                }
            } else if applied == text {
                cell.insertionExact += 1
            }
        }

        if checkValidity {
            cell.validitySites += 1
            // Control: a name that cannot exist must be flagged, or the detector below proves nothing.
            cell.controlsChecked += 1
            let nonsense = ns.replacingCharacters(
                in: NSRange(location: site.startUTF16, length: site.endUTF16 - site.startUTF16), with: "zzNoSuchMember"
            )
            var controlAlive = false
            let controlDiagnostics = try? await client.check(moduleId: projectName, file: file, text: nonsense)
            if let controlDiagnostics, invalidAt(controlDiagnostics, end: site.startUTF16 + "zzNoSuchMember".utf16.count, baseline: baseline) {
                cell.controlsDetected += 1
                controlAlive = true
            } else {
                // Why this site cannot be validated, in the order a reader would debug it.
                let reason: String
                if controlDiagnostics == nil { reason = "check-failed" }
                else if baseline.setupFailure { reason = "compiler-setup (module or classpath)" }
                else if baseline.errors > 0 { reason = "file-has-baseline-errors" }
                else if controlDiagnostics!.contains(where: { $0.severity == .error }) { reason = "other-error-blocked-attribution" }
                else { reason = "control-not-reported" }
                report.controlReasons[reason, default: 0] += 1
                if ProcessInfo.processInfo.environment["JAVA_QUALITY_CONTROL_DEBUG"] != nil {
                    let keys = (controlDiagnostics ?? []).map { "\($0.severity.rawValue):\($0.key)@\($0.start ?? -1)" }
                    print("CONTROL-MISS \(reason) \(fileLabel)@\(site.startUTF16) `\(site.name)` keys=\(keys.prefix(6))")
                }
            }
            guard controlAlive else { return cell }
            // Same kind as the developer's symbol: a method name in a field position is a kind error, not an
            // invalid member.
            let kinds: Set<CompletionItemKind> = symbolKind == "method" ? [.method] : [.field, .enumMember]
            let alternatives = ranked.prefix(3).map(\.item).filter { kinds.contains($0.kind) }
            for item in alternatives where item.label != site.name {
                cell.candidatesChecked += 1
                let swapped = ns.replacingCharacters(
                    in: NSRange(location: site.startUTF16, length: site.endUTF16 - site.startUTF16), with: item.label
                )
                guard let diagnostics = try? await client.check(moduleId: projectName, file: file, text: swapped) else {
                    cell.candidatesChecked -= 1
                    continue
                }
                let bad = invalidAt(diagnostics, end: site.startUTF16 + item.label.utf16.count, baseline: baseline)
                if bad {
                    cell.candidatesInvalid += 1
                    if report.invalidSamples.count < 40 {
                        report.invalidSamples.append("\(context) `\(item.label)` instead of `\(site.name)` in \(projectName)/\(fileLabel)@\(site.startUTF16)")
                    }
                }
            }
        }
        return cell
    }

    /// `javac` keys meaning "this member cannot be named here" (not an argument or type mismatch).
    static let invalidKeys = ["cant.resolve", "report.access", "not.def.public", "non-static.cant.be.ref", "abstract.cant.be.accessed"]

    static func isInvalidKey(_ key: String) -> Bool { invalidKeys.contains { key.contains($0) } }

    /// Whether javac rejects the member written at the site: an error of an "invalid member" kind whose
    /// span ends exactly where the swapped name ends. A different method substituted mid-chain can break the
    /// *next* member (`x.getClass().foo`), which is the chain's problem, not the candidate's, and ends later.
    static func invalidAt(_ diagnostics: [JavaAnalysisServerDiagnostic], end: Int, baseline: FileBaseline) -> Bool {
        !baseline.invalidEnds.contains(end) && diagnostics.contains {
            $0.severity == .error && isInvalidKey($0.key) && $0.end == end
        }
    }

    // MARK: - Insertion

    static func nextCharacter(in text: String, at range: EditorIntelligence.TextRange) -> String? {
        let ns = text as NSString
        let offset = range.end.utf16Offset
        guard offset < ns.length else { return nil }
        return ns.substring(with: NSRange(location: offset, length: 1))
    }

    /// Up to 16 characters after the replaced range: what the editor hands `CompletionInsertion`.
    static func following(in text: String, at range: EditorIntelligence.TextRange) -> String {
        let ns = text as NSString
        let start = min(range.end.utf16Offset, ns.length)
        return ns.substring(with: NSRange(location: start, length: min(16, ns.length - start)))
    }

    /// The document after accepting `item` the way the editor does for a plain or snippet item.
    static func apply(_ item: CompletionItem, to text: String) -> String {
        let ns = text as NSString
        let resolution = CompletionInsertion.resolve(item, nextCharacter: nextCharacter(in: text, at: item.range), following: following(in: text, at: item.range))
        let insertText = resolution.isSnippet ? collapseSnippet(resolution.text) : resolution.text
        var edits = item.additionalEdits.map { ($0.range.start.utf16Offset, $0.range.end.utf16Offset, $0.replacement) }
        edits.append((item.range.start.utf16Offset, item.range.end.utf16Offset, insertText))
        edits.sort { $0.0 > $1.0 }
        var result = ns
        for (start, end, replacement) in edits where start >= 0 && end <= result.length && start <= end {
            result = result.replacingCharacters(in: NSRange(location: start, length: end - start), with: replacement) as NSString
        }
        return result as String
    }

    /// Default text of a TextMate snippet: `${1:name}` → `name`, `$0`/`$1` → empty.
    static func collapseSnippet(_ snippet: String) -> String {
        var result = snippet
        result = result.replacingOccurrences(of: #"\$\{\d+:([^}]*)\}"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\$\{\d+\}|\$\d+"#, with: "", options: .regularExpression)
        return result
    }

    // MARK: - Context

    /// A declarator, parameter, method or annotation element named here: the developer is naming
    /// something new, so there is nothing to recall. (The role map misses some of these.)
    static func isDeclarationName(site: JavaDifferentialHarness.IdentifierSite, text: String, tree: JavaSyntaxTree) -> Bool {
        guard let byte = JavaDifferentialHarness.byteOffset(of: site.startUTF16, in: text) else { return false }
        let node = tree.node(atByteOffset: byte)
        guard let parent = node.parent else { return false }
        let declarations: Set<String> = [
            "variable_declarator", "formal_parameter", "spread_parameter", "catch_formal_parameter",
            "method_declaration", "annotation_type_element_declaration", "enum_constant", "resource",
            "class_declaration", "interface_declaration", "enum_declaration", "record_declaration",
            "constant_declaration", "type_parameter", "lambda_expression", "inferred_parameters",
        ]
        guard declarations.contains(parent.type) else { return false }
        if parent.type == "inferred_parameters" || parent.type == "lambda_expression" { return true }
        return parent.child(byFieldName: "name")?.startByte == node.startByte
    }

    static func classify(
        site: JavaDifferentialHarness.IdentifierSite, symbol: JavaAnalysisSymbol, role: JavaIdentifierRole?,
        text: String, tree: JavaSyntaxTree
    ) -> String {
        if role == .imported { return "import" }
        let byte = JavaDifferentialHarness.byteOffset(of: site.startUTF16, in: text) ?? 0
        var node: SyntaxNode? = tree.node(atByteOffset: byte)
        var inLambda = false
        var inTypeArguments = false
        var afterNew = false
        while let current = node {
            switch current.type {
            case "import_declaration": return "import"
            case "lambda_expression": inLambda = true
            case "type_arguments": inTypeArguments = true
            case "object_creation_expression":
                if let type = current.child(byFieldName: "type"), type.byteRange.contains(byte) { afterNew = true }
            default: break
            }
            node = current.parent
        }
        if afterNew { return "constructor" }
        if inTypeArguments { return "generic" }
        let dotted = JavaDifferentialHarness.isDotted(at: site.startUTF16, in: text)
        switch symbol.kind {
        case "local_variable", "parameter", "exception_parameter", "resource_variable", "binding_variable":
            return inLambda ? "lambda" : "local"
        case "field", "enum_constant", "record_component", "method":
            if inLambda, !dotted { return "lambda" }
            if dotted {
                let ns = text as NSString
                var index = site.startUTF16 - 1
                while index >= 0, [0x20, 0x09, 0x0A, 0x0D].contains(ns.character(at: index)) { index -= 1 }
                // index is the dot; the character before it decides the shape of the receiver.
                var before = index - 1
                while before >= 0, [0x20, 0x09, 0x0A, 0x0D].contains(ns.character(at: before)) { before -= 1 }
                if before >= 0, ns.character(at: before) == 0x29 { return "chain" } // ')'
                var start = before
                while start >= 0, let scalar = Unicode.Scalar(ns.character(at: start)),
                      CharacterSet.alphanumerics.contains(scalar) || scalar == "_" { start -= 1 }
                if start < before, let scalar = Unicode.Scalar(ns.character(at: start + 1)),
                   CharacterSet.uppercaseLetters.contains(scalar) { return "static" }
                return symbol.kind == "method" ? "method" : "field"
            }
            return symbol.kind == "method" ? "method" : "field"
        case "class", "interface", "enum", "record", "annotation_type", "type_parameter":
            return "type"
        default:
            return "other"
        }
    }

    // MARK: - Rendering

    static let tableHeader = "context      sites  R@1    R@3    R@8    MRR    empty  absent dup@8  insBad(parse)   exact    invalid        control"

    static func table(_ variant: String, _ cells: [String: Accumulator]) -> [String] {
        var lines = [tableHeader]
        var total = Accumulator()
        for context in contexts {
            guard let cell = cells["\(variant)/\(context)"] else { continue }
            lines.append(row(context, cell))
            total = merged(total, cell)
        }
        lines.append(row("ALL", total))
        return lines
    }

    static func total(_ variant: String, _ cells: [String: Accumulator]) -> Accumulator {
        contexts.reduce(Accumulator()) { merged($0, cells["\(variant)/\($1)"] ?? Accumulator()) }
    }

    /// Validation coverage: of the sites eligible for the javac check, how many had a working
    /// negative control, and only then how many alternatives were checked and found invalid.
    static func validityLine(_ cells: [String: Accumulator]) -> String {
        let t = total("complete", cells)
        return "eligible sites \(t.validitySites); validated (control fired) \(t.controlsDetected) = \(pct(t.controlsDetected, t.validitySites).trimmingCharacters(in: .whitespaces)) coverage; "
            + "alternatives checked on validated sites \(t.candidatesChecked); invalid among them \(t.candidatesInvalid)"
    }

    static func render(_ results: [ProjectResult]) -> String {
        var lines: [String] = []
        for group in ["development", "held-out"] {
            let members = results.filter { $0.project.group == group }
            guard !members.isEmpty else { continue }
            lines.append("")
            lines.append("################ \(group.uppercased()) — \(members.map(\.project.name).joined(separator: ", ")) ################")
            var groupCells: [String: Accumulator] = [:]
            var groupExclusions: [String: Int] = [:]
            var groupReasons: [String: Int] = [:]
            var sampled = 0, files = 0, clean = 0
            for result in members {
                let report = result.report
                lines.append("")
                lines.append("--- \(result.project.name) (\(result.project.note)) prefix \(report.prefixLength), JDK \(report.jdkFeature)")
                lines.append("files sampled \(report.filesSampled), compile cleanly as-is \(report.filesCleanCompile); sites sampled \(report.sitesSampled), scored \(total("complete", report.cells).sites)")
                lines.append("[complete]"); lines += table("complete", report.cells)
                lines.append("[complete, files that compile cleanly only]"); lines += table("complete-clean", report.cells)
                lines.append("validity: " + validityLine(report.cells))
                for (key, value) in report.cells { groupCells[key] = merged(groupCells[key] ?? Accumulator(), value) }
                for (key, value) in report.exclusions { groupExclusions[key, default: 0] += value }
                for (key, value) in report.controlReasons { groupReasons[key, default: 0] += value }
                sampled += report.sitesSampled; files += report.filesSampled; clean += report.filesCleanCompile
            }
            lines.append("")
            lines.append("=== \(group) aggregate over \(members.count) project(s): files \(files) (\(clean) compile cleanly), sites sampled \(sampled)")
            lines.append("[complete]"); lines += table("complete", groupCells)
            lines.append("[broken-line]"); lines += table("broken-line", groupCells)
            lines.append("[complete, clean-compiling files only]"); lines += table("complete-clean", groupCells)
            lines.append("validity: " + validityLine(groupCells))
            lines.append("exclusions (of \(sampled) sampled sites):")
            for (reason, count) in groupExclusions.sorted(by: { $0.value > $1.value }) { lines.append("  \(count)  \(reason)") }
            if !groupReasons.isEmpty {
                lines.append("negative control unusable, by reason (each is an eligible site left unvalidated):")
                for (reason, count) in groupReasons.sorted(by: { $0.value > $1.value }) { lines.append("  \(count)  \(reason)") }
            }
            var keys: [String: Int] = [:]
            for result in members { for (key, value) in result.report.baselineErrorKeys { keys[key, default: 0] += value } }
            if !keys.isEmpty {
                lines.append("javac errors on the unmodified sampled files, by key (top 6):")
                for (key, count) in keys.sorted(by: { $0.value > $1.value }).prefix(6) { lines.append("  \(count)  \(key)") }
            }
        }
        return lines.joined(separator: "\n")
    }

    static func merged(_ a: Accumulator, _ b: Accumulator) -> Accumulator {
        var r = a
        r.sites += b.sites; r.recall1 += b.recall1; r.recall3 += b.recall3; r.recall8 += b.recall8
        r.reciprocalRank += b.reciprocalRank; r.empty += b.empty; r.absent += b.absent
        r.top8Slots += b.top8Slots; r.top8Duplicates += b.top8Duplicates
        r.insertionChecked += b.insertionChecked; r.insertionBad += b.insertionBad; r.insertionExact += b.insertionExact
        r.controlsChecked += b.controlsChecked; r.controlsDetected += b.controlsDetected
        r.candidatesChecked += b.candidatesChecked; r.candidatesInvalid += b.candidatesInvalid
        r.validitySites += b.validitySites
        return r
    }

    static func pct(_ n: Int, _ d: Int) -> String {
        d == 0 ? "   -  " : String(format: "%5.1f%%", Double(n) * 100 / Double(d))
    }

    static func row(_ name: String, _ c: Accumulator) -> String {
        let mrr = c.sites == 0 ? "  -   " : String(format: "%.3f ", c.reciprocalRank / Double(c.sites))
        let name = name.padding(toLength: 12, withPad: " ", startingAt: 0)
        let sites = String(c.sites).padding(toLength: 6, withPad: " ", startingAt: 0)
        return "\(name) \(sites) \(pct(c.recall1, c.sites)) \(pct(c.recall3, c.sites)) \(pct(c.recall8, c.sites)) \(mrr) \(pct(c.empty, c.sites)) \(pct(c.absent, c.sites)) \(pct(c.top8Duplicates, c.top8Slots)) \(pct(c.insertionBad, c.insertionChecked)) (\(c.insertionBad)/\(c.insertionChecked)) \(pct(c.insertionExact, c.insertionChecked)) \(pct(c.candidatesInvalid, c.candidatesChecked)) (\(c.candidatesInvalid)/\(c.candidatesChecked)) \(c.controlsDetected)/\(c.controlsChecked)"
    }
}

/// Document frequency of every identifier under `root`: the same shape as `JavaNameIndex`'s answer.
struct ProjectWordCounts: JavaUsageStatisticsSource {
    let counts: [String: Int]

    init(roots: [URL]) {
        var counts: [String: Int] = [:]
        let expression = try? NSRegularExpression(pattern: #"[A-Za-z_$][A-Za-z0-9_$]*"#)
        for file in roots.flatMap({ JavaDifferentialHarness.javaFiles(under: $0, limit: Int.max) }) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var seen = Set<String>()
            let ns = text as NSString
            expression?.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                if let match { seen.insert(ns.substring(with: match.range)) }
            }
            for word in seen { counts[word, default: 0] += 1 }
        }
        self.counts = counts
    }

    func fileCounts(ofIdentifiers identifiers: [String]) async -> [String: Int] {
        var result: [String: Int] = [:]
        for identifier in identifiers { if let count = counts[identifier] { result[identifier] = count } }
        return result
    }
}

final class JavaCompletionQualityTests: XCTestCase {
    /// `JAVA_QUALITY=1 swift test --filter JavaCompletionQualityTests`; `JAVA_QUALITY_OUT=path.json`
    /// saves the numbers for a before/after comparison.
    func testQualityBaseline() async throws {
        guard ProcessInfo.processInfo.environment["JAVA_QUALITY"] == "1" else {
            throw XCTSkip("Set JAVA_QUALITY=1 (and JAVA_QUALITY_SET=development|held-out|all) to score completion")
        }
        let set = ProcessInfo.processInfo.environment["JAVA_QUALITY_SET"] ?? "development"
        let results = try await JavaCompletionQualityHarness.run(set: set)
        var output = JavaCompletionQualityHarness.render(results)
        // Code samples only for the public projects: the held-out Gradle projects are private.
        for result in results where result.project.model == nil {
            output += "\n\n[\(result.project.name)] misses:\n" + result.report.misses.joined(separator: "\n")
            output += "\n[\(result.project.name)] invalid candidates:\n" + result.report.invalidSamples.joined(separator: "\n")
            output += "\n[\(result.project.name)] bad insertions:\n" + result.report.insertionSamples.joined(separator: "\n")
        }
        for result in results where result.project.model != nil {
            output += "\n\n[\(result.project.name)] bad insertions (private project, local only):\n" + result.report.insertionSamples.joined(separator: "\n")
        }
        print(output)
        if let path = ProcessInfo.processInfo.environment["JAVA_QUALITY_OUT"] {
            try output.write(toFile: path, atomically: true, encoding: .utf8)
            let data = try JSONEncoder().encode(Dictionary(uniqueKeysWithValues: results.map { ($0.project.name, $0.report) }))
            try data.write(to: URL(fileURLWithPath: path + ".json"))
        }
        XCTAssertGreaterThan(results.flatMap { $0.report.cells.values }.reduce(0) { $0 + $1.sites }, 0)
    }

    func testInsertionDoesNotDuplicateExistingParentheses() {
        let item = CompletionItem(
            label: "length", insertText: "length()", kind: .method,
            range: EditorIntelligence.TextRange(
                start: TextPosition(line: 0, column: 2, utf16Offset: 2),
                end: TextPosition(line: 0, column: 3, utf16Offset: 3)
            ),
            source: "test", caretOffset: nil
        )
        XCTAssertEqual(JavaCompletionQualityHarness.apply(item, to: "s.l(1);"), "s.length(1);")
        XCTAssertEqual(JavaCompletionQualityHarness.apply(item, to: "s.l;"), "s.length();")
    }
}
