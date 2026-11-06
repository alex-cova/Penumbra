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
    static let defaultUsagesPerProject = 2

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
        /// J2: why a scored definition missed, plus how many candidates the resolver returned
        /// and whether the oracle's declaration lives in the indexed source shard.
        var definitionOutcome: DefinitionOutcome = .unscored
        var definitionCandidates = 0
        var declarationInSource = false
        var completionScored = false
        /// Ranked top-8: the popup's list after `DefaultRanker`, with the identifier tail deleted
        /// and a `.keystroke` trigger, the way the popup sees a typed prefix.
        var completionHit = false
        /// The previous metric (raw provider order, tail kept) for one revision, so the jump is
        /// explained side by side instead of silently moving the baseline.
        var legacyCompletionHit = false
        /// 1-based rank in the ranked list, or nil when the symbol is absent (or the list empty).
        var completionRank: Int?
        var completionEmpty = false
        /// J1: the site's syntactic role and whether a `.` precedes it (member/call through a receiver).
        var siteRole: JavaIdentifierRole?
        var siteDotted = false
        var hoverScored = false
        var hoverHit = false
        /// Whether definition matched at a site where hover missed (a rendering gap, not resolution).
        var hoverDefinitionHit = false
        var note = ""
    }

    /// Why a scored definition missed. `matched` and `unscored` are not misses.
    enum DefinitionOutcome: String, Sendable {
        case unscored
        case matched
        /// The resolver answered nothing.
        case noAnswer
        /// An answer landed outside the oracle's file.
        case otherFile
        /// An answer landed in the oracle's file but outside the declaration lines
        /// (usually an overload or the enclosing declaration).
        case sameFileOtherLines
    }

    /// Rank buckets for the J1 distribution: `belowFold` is in the list but past the
    /// popup's 8, `absent` is a non-empty list without the symbol, `empty` is no items.
    enum CompletionRankBucket: String, CaseIterable, Sendable {
        case top1 = "1"
        case top2to3 = "2-3"
        case top4to8 = "4-8"
        case belowFold = "9+"
        case absent
        case empty

        init(rank: Int?, empty: Bool) {
            if empty { self = .empty; return }
            guard let rank else { self = .absent; return }
            switch rank {
            case 1: self = .top1
            case 2...3: self = .top2to3
            case 4...8: self = .top4to8
            default: self = .belowFold
            }
        }
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
        var usagesScored: Int = 0
        var usagesMatched: Int = 0
        var usagesAnswered: Int = 0
        /// Previous metric (raw provider order) for one revision; informational, never ratcheted.
        var legacyCompletionHit: Int = 0
        /// Ranked top-8 on non-declaration sites (the first headline split).
        var completionScoredNonDeclared: Int = 0
        var completionHitNonDeclared: Int = 0
        /// Ranked top-8 on dotted call/member sites (the receiver-typing split).
        var completionScoredDotted: Int = 0
        var completionHitDotted: Int = 0
        /// J2 definition miss buckets: no answer / other file / same file, other lines.
        var definitionNoAnswer: Int = 0
        var definitionOtherFile: Int = 0
        var definitionSameFileOtherLines: Int = 0
        /// Ranked-list rank buckets over all completion sites, in `CompletionRankBucket` order.
        var rankBuckets: [Int] = []

        init(
            name: String, tag: String, commit: String, files: Int, positions: Int,
            attributeFailures: Int, definitionScored: Int, definitionMatched: Int,
            definitionAnswered: Int, completionScored: Int, completionHit: Int,
            hoverScored: Int, hoverHit: Int, usagesScored: Int = 0, usagesMatched: Int = 0,
            usagesAnswered: Int = 0, legacyCompletionHit: Int = 0,
            completionScoredNonDeclared: Int = 0, completionHitNonDeclared: Int = 0,
            completionScoredDotted: Int = 0, completionHitDotted: Int = 0,
            definitionNoAnswer: Int = 0, definitionOtherFile: Int = 0,
            definitionSameFileOtherLines: Int = 0, rankBuckets: [Int] = []
        ) {
            self.name = name
            self.tag = tag
            self.commit = commit
            self.files = files
            self.positions = positions
            self.attributeFailures = attributeFailures
            self.definitionScored = definitionScored
            self.definitionMatched = definitionMatched
            self.definitionAnswered = definitionAnswered
            self.completionScored = completionScored
            self.completionHit = completionHit
            self.hoverScored = hoverScored
            self.hoverHit = hoverHit
            self.usagesScored = usagesScored
            self.usagesMatched = usagesMatched
            self.usagesAnswered = usagesAnswered
            self.legacyCompletionHit = legacyCompletionHit
            self.completionScoredNonDeclared = completionScoredNonDeclared
            self.completionHitNonDeclared = completionHitNonDeclared
            self.completionScoredDotted = completionScoredDotted
            self.completionHitDotted = completionHitDotted
            self.definitionNoAnswer = definitionNoAnswer
            self.definitionOtherFile = definitionOtherFile
            self.definitionSameFileOtherLines = definitionSameFileOtherLines
            self.rankBuckets = rankBuckets
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            tag = try container.decode(String.self, forKey: .tag)
            commit = try container.decode(String.self, forKey: .commit)
            files = try container.decode(Int.self, forKey: .files)
            positions = try container.decode(Int.self, forKey: .positions)
            attributeFailures = try container.decode(Int.self, forKey: .attributeFailures)
            definitionScored = try container.decode(Int.self, forKey: .definitionScored)
            definitionMatched = try container.decode(Int.self, forKey: .definitionMatched)
            definitionAnswered = try container.decode(Int.self, forKey: .definitionAnswered)
            completionScored = try container.decode(Int.self, forKey: .completionScored)
            completionHit = try container.decode(Int.self, forKey: .completionHit)
            hoverScored = try container.decode(Int.self, forKey: .hoverScored)
            hoverHit = try container.decode(Int.self, forKey: .hoverHit)
            usagesScored = try container.decodeIfPresent(Int.self, forKey: .usagesScored) ?? 0
            usagesMatched = try container.decodeIfPresent(Int.self, forKey: .usagesMatched) ?? 0
            usagesAnswered = try container.decodeIfPresent(Int.self, forKey: .usagesAnswered) ?? 0
            legacyCompletionHit = try container.decodeIfPresent(Int.self, forKey: .legacyCompletionHit) ?? 0
            completionScoredNonDeclared = try container.decodeIfPresent(Int.self, forKey: .completionScoredNonDeclared) ?? 0
            completionHitNonDeclared = try container.decodeIfPresent(Int.self, forKey: .completionHitNonDeclared) ?? 0
            completionScoredDotted = try container.decodeIfPresent(Int.self, forKey: .completionScoredDotted) ?? 0
            completionHitDotted = try container.decodeIfPresent(Int.self, forKey: .completionHitDotted) ?? 0
            definitionNoAnswer = try container.decodeIfPresent(Int.self, forKey: .definitionNoAnswer) ?? 0
            definitionOtherFile = try container.decodeIfPresent(Int.self, forKey: .definitionOtherFile) ?? 0
            definitionSameFileOtherLines = try container.decodeIfPresent(Int.self, forKey: .definitionSameFileOtherLines) ?? 0
            rankBuckets = try container.decodeIfPresent([Int].self, forKey: .rankBuckets) ?? []
        }

        var wrongSymbols: Int { definitionAnswered - definitionMatched }
        var wrongUsages: Int { usagesAnswered - usagesMatched }
    }

    struct Report: Codable, Equatable {
        var jdkFeature: Int
        var filesPerProject: Int
        var positionsPerFile: Int
        var usagesPerProject: Int = 0
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
                || usagesPerProject != baseline.usagesPerProject
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
                    || project.usagesScored != previous.usagesScored
                if sampleChanged {
                    lines.append("\(project.name) scored a different sample (definition \(project.definitionScored) vs \(previous.definitionScored), completion \(project.completionScored) vs \(previous.completionScored), usages \(project.usagesScored) vs \(previous.usagesScored)): re-run with UPDATE_JAVA_DIFFERENTIAL=1")
                    continue
                }
                lines += compare(project.name, "definition recall", project.definitionMatched, previous.definitionMatched, higherIsBetter: true)
                lines += compare(project.name, "wrong-symbol", project.wrongSymbols, previous.wrongSymbols, higherIsBetter: false)
                lines += compare(project.name, "completion top-\(topK)", project.completionHit, previous.completionHit, higherIsBetter: true)
                lines += compare(project.name, "completion top-\(topK) non-declared", project.completionHitNonDeclared, previous.completionHitNonDeclared, higherIsBetter: true)
                lines += compare(project.name, "completion top-\(topK) dotted", project.completionHitDotted, previous.completionHitDotted, higherIsBetter: true)
                lines += compare(project.name, "hover", project.hoverHit, previous.hoverHit, higherIsBetter: true)
                lines += compare(project.name, "usages recall", project.usagesMatched, previous.usagesMatched, higherIsBetter: true)
                lines += compare(project.name, "wrong-usages", project.wrongUsages, previous.wrongUsages, higherIsBetter: false)
            }
            let missing = baseline.projects.map(\.name).filter { name in !projects.contains { $0.name == name } }
            for name in missing {
                lines.append("MISSING PROJECT \(name)")
            }
            return lines
        }

        var summary: String {
            projects.map { project in
                "\(project.name) \(project.commit.prefix(12)) definition \(format(project.definitionMatched, project.definitionScored)) wrong-symbol \(format(project.wrongSymbols, project.definitionAnswered)) completion \(format(project.completionHit, project.completionScored)) non-declared \(format(project.completionHitNonDeclared, project.completionScoredNonDeclared)) dotted \(format(project.completionHitDotted, project.completionScoredDotted)) hover \(format(project.hoverHit, project.hoverScored)) usages \(format(project.usagesMatched, project.usagesScored)) wrong-usages \(format(project.wrongUsages, project.usagesAnswered))"
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
                "  The ranked popup is scored: the identifier tail is deleted, the trigger is `.keystroke`,",
                "  and `DefaultRanker` orders the list, the way the popup sees a typed prefix.",
                "- Completion (provider order): the previous metric, raw provider order with the tail kept,",
                "  for one revision so the jump is explained side by side.",
                "- Hover: an explicit hover contains the symbol's name.",
                "- Usages recall: of the sampled public method declarations with at least one oracle use, the share whose reference set (file and line, declarations dropped) matches the oracle's `usages` exactly.",
                "- Wrong-usages: of the declarations the provider answers, the share whose set differs.",
                "",
                "The same shape applies later to TypeScript (`tsserver`) and Swift (`sourcekit-lsp`).",
                "",
                "| project | commit | definition recall | wrong-symbol | completion top-\(topK) | completion (provider order) | hover | usages recall | wrong-usages |",
                "|---|---|---|---|---|---|---|---|---|",
            ]
            for project in projects {
                lines.append("| \(project.name) | `\(project.commit)` | \(format(project.definitionMatched, project.definitionScored)) | \(format(project.wrongSymbols, project.definitionAnswered)) | \(format(project.completionHit, project.completionScored)) | \(format(project.legacyCompletionHit, project.completionScored)) | \(format(project.hoverHit, project.hoverScored)) | \(format(project.usagesMatched, project.usagesScored)) | \(format(project.wrongUsages, project.usagesAnswered)) |")
            }
            lines.append("")
            lines.append("Sample: \(filesPerProject) files per project, \(positionsPerFile) identifiers per file, stride-picked so one package cannot fill the run; \(usagesPerProject) public method declarations per project for usages (each oracle call compiles the whole module, so this stays small).")
            lines.append("")
            lines.append("Ranked completion, all sites: \(format(projects.map(\.completionHit).reduce(0, +), projects.map(\.completionScored).reduce(0, +))).")
            lines.append("Excluding declarations: \(format(projects.map(\.completionHitNonDeclared).reduce(0, +), projects.map(\.completionScoredNonDeclared).reduce(0, +))).")
            lines.append("Dotted call/member only: \(format(projects.map(\.completionHitDotted).reduce(0, +), projects.map(\.completionScoredDotted).reduce(0, +))).")
            lines.append("Rank buckets (1 / 2-3 / 4-8 / 9+ / absent / empty): \(bucketLine(projects.map(\.rankBuckets))).")
            lines.append("Definition misses (no answer / other file / same file, other lines): \(projects.map(\.definitionNoAnswer).reduce(0, +)) / \(projects.map(\.definitionOtherFile).reduce(0, +)) / \(projects.map(\.definitionSameFileOtherLines).reduce(0, +)).")
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
        let usagesPerProject = intEnv("JAVA_DIFFERENTIAL_USAGES", default: defaultUsagesPerProject)
        let jdkShard = try writeJDKShard(installation: environment.jdk)
        var projects: [ProjectScore] = []
        for pinned in pinnedProjects {
            let checkout = try checkout(pinned)
            let sourceRoot = checkout.sourceRoot.resolvingSymlinksInPath()
            try await client.configure(JavaAnalysisServerModule(moduleId: pinned.name, sourcepath: [sourceRoot]))
            let world = try await makeWorld(sourceRoot: sourceRoot, jdkShard: jdkShard, installation: environment.jdk)
            var score = await score(
                name: pinned.name, tag: pinned.tag, commit: checkout.commit,
                sourceRoot: sourceRoot, moduleId: pinned.name, client: client, world: world,
                filesPerProject: filesPerProject, positionsPerFile: positionsPerFile
            )
            if usagesPerProject > 0 {
                let files = javaFiles(under: sourceRoot, limit: filesPerProject)
                let usage = await scoreUsages(
                    name: pinned.name, sourceRoot: sourceRoot, moduleId: pinned.name,
                    client: client, world: world, files: files, limit: usagesPerProject
                )
                score.usagesScored = usage.scored
                score.usagesMatched = usage.matched
                score.usagesAnswered = usage.answered
            }
            projects.append(score)
            print("differential \(score.name) \(format(score.definitionMatched, score.definitionScored)) definition, \(format(score.completionHit, score.completionScored)) completion, \(format(score.usagesMatched, score.usagesScored)) usages")
        }
        return Report(
            jdkFeature: environment.jdk.featureVersion,
            filesPerProject: filesPerProject,
            positionsPerFile: positionsPerFile,
            usagesPerProject: usagesPerProject,
            topK: topK,
            prefixLength: prefixLength,
            projects: projects
        )
    }

    /// Find-Usages recall on up to `limit` public method declarations sampled across `files`:
    /// the oracle's `(file, line)` site set against the provider's, declarations dropped on both
    /// sides. Each oracle call compiles the whole module, so the sample stays small.
    static func scoreUsages(
        name: String, sourceRoot: URL, moduleId: String, client: JavaAnalysisServerClient,
        world: World, files: [URL], limit: Int
    ) async -> (scored: Int, matched: Int, answered: Int) {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("differential-usages-\(UUID().uuidString)", isDirectory: true)
        let nameIndex = JavaNameIndex(paths: JavaIndexPaths(root: cacheRoot))
        for await _ in await nameIndex.build(roots: [sourceRoot]) {}
        let provider = JavaFindUsagesProvider(
            index: world.index, indexPaths: JavaIndexPaths(root: cacheRoot), nameIndex: nameIndex)
        await provider.setProjectRoots([sourceRoot])
        var declarations: [(file: URL, text: String, utf16Offset: Int)] = []
        for file in files {
            guard declarations.count < limit * 3,
                  let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for site in methodDeclarations(in: text, limit: limit * 3 - declarations.count) {
                declarations.append((file, text, site.utf16Offset))
            }
        }
        var scored = 0, matched = 0, answered = 0, calls = 0
        for declaration in declarations {
            guard scored < limit, calls < limit * 3 else { break }
            let resolved = declaration.file.resolvingSymlinksInPath()
            let usages: [JavaAnalysisUsage]
            do {
                usages = try await client.usages(
                    moduleId: moduleId, file: resolved, text: declaration.text, position: declaration.utf16Offset)
            } catch {
                print("differential \(name) \(resolved.lastPathComponent) usages failed: \(error)")
                continue
            }
            guard !usages.isEmpty else { continue }
            calls += 1
            let expected = Set(usages.compactMap { usage -> String? in
                let fileName = URL(fileURLWithPath: usage.file).lastPathComponent
                if fileName == resolved.lastPathComponent,
                   usage.offset <= declaration.utf16Offset, declaration.utf16Offset < usage.offset + usage.length {
                    return nil
                }
                return "\(fileName):\(usage.line)"
            })
            let found = await provider.findUsages(
                source: declaration.text, url: resolved, utf16Offset: declaration.utf16Offset)
            let provided = Set(found.map { "\($0.url.lastPathComponent):\($0.line + 1)" })
            // Recall needs something to find: an unused declaration scores nothing.
            guard !expected.isEmpty else { continue }
            scored += 1
            if !provided.isEmpty { answered += 1 }
            if provided == expected {
                matched += 1
            } else {
                print("differential \(name) usages differ at \(resolved.lastPathComponent):\(declaration.utf16Offset): provider \(provided.sorted()) oracle \(expected.sorted())")
            }
        }
        return (scored, matched, answered)
    }

    /// Public method declarations in file order: name and its UTF-16 offset.
    static func methodDeclarations(in text: String, limit: Int) -> [(name: String, utf16Offset: Int)] {
        guard let tree = JavaSyntaxParser().parse(text) else { return [] }
        var out: [(String, Int)] = []
        func utf16Offset(of byteOffset: Int) -> Int? {
            guard let index = text.utf8.index(text.utf8.startIndex, offsetBy: byteOffset, limitedBy: text.utf8.endIndex),
                  let mapped = index.samePosition(in: text.utf16) else { return nil }
            return text.utf16.distance(from: text.utf16.startIndex, to: mapped)
        }
        func visit(_ node: SyntaxNode) {
            guard out.count < limit else { return }
            if node.type == "method_declaration",
               let modifiers = node.namedChildren.first(where: { $0.type == "modifiers" }),
               modifiers.text.contains("public"),
               let name = node.child(byFieldName: "name"),
               let offset = utf16Offset(of: name.byteRange.lowerBound) {
                out.append((name.text, offset))
            }
            for child in node.namedChildren { visit(child) }
        }
        visit(tree.rootNode)
        return out
    }

    /// One project directory. `commit` is recorded as-is (a fixture passes a label).
    /// Per-site detail for the printed J1 bucket table (kept out of `ProjectScore`).
    struct SiteDetail: Sendable {
        var role: JavaIdentifierRole?
        var dotted: Bool
        var rank: Int?
        var empty: Bool
    }

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
        var details: [SiteDetail] = []
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
            let roles = roleMap(in: text)
            score.positions += sites.count
            for site in sites {
                guard let symbol = byPosition[site.lastUTF16] else { continue }
                let verdict = await self.verdict(
                    site: site, symbol: symbol, text: text, file: resolved,
                    world: world, roles: roles, sourceRoot: sourceRoot
                )
                if verdict.definitionScored {
                    score.definitionScored += 1
                    if verdict.definitionMatched { score.definitionMatched += 1 }
                    if verdict.definitionAnswered { score.definitionAnswered += 1 }
                    switch verdict.definitionOutcome {
                    case .noAnswer: score.definitionNoAnswer += 1
                    case .otherFile: score.definitionOtherFile += 1
                    case .sameFileOtherLines: score.definitionSameFileOtherLines += 1
                    case .unscored, .matched: break
                    }
                }
                if verdict.completionScored {
                    score.completionScored += 1
                    if verdict.completionHit { score.completionHit += 1 }
                    if verdict.legacyCompletionHit { score.legacyCompletionHit += 1 }
                    let bucket = CompletionRankBucket(rank: verdict.completionRank, empty: verdict.completionEmpty)
                    if score.rankBuckets.isEmpty {
                        score.rankBuckets = Array(repeating: 0, count: CompletionRankBucket.allCases.count)
                    }
                    if let index = CompletionRankBucket.allCases.firstIndex(of: bucket) {
                        score.rankBuckets[index] += 1
                    }
                    let nonDeclared = verdict.siteRole != .declared
                    if nonDeclared {
                        score.completionScoredNonDeclared += 1
                        if verdict.completionHit { score.completionHitNonDeclared += 1 }
                    }
                    if verdict.siteDotted, verdict.siteRole == .call || verdict.siteRole == .member {
                        score.completionScoredDotted += 1
                        if verdict.completionHit { score.completionHitDotted += 1 }
                    }
                    details.append(SiteDetail(
                        role: verdict.siteRole, dotted: verdict.siteDotted,
                        rank: verdict.completionRank, empty: verdict.completionEmpty
                    ))
                }
                if verdict.hoverScored {
                    score.hoverScored += 1
                    if verdict.hoverHit { score.hoverHit += 1 }
                }
            }
        }
        print(bucketReport(name: name, score: score, details: details))
        return score
    }

    /// The three J1 headline rates plus the rank-bucket table per site role.
    static func bucketReport(name: String, score: ProjectScore, details: [SiteDetail]) -> String {
        var lines = [
            "differential \(name) completion \(format(score.completionHit, score.completionScored)) "
                + "non-declared \(format(score.completionHitNonDeclared, score.completionScoredNonDeclared)) "
                + "dotted \(format(score.completionHitDotted, score.completionScoredDotted)) "
                + "legacy \(format(score.legacyCompletionHit, score.completionScored))",
            "differential \(name) definition misses no-answer \(score.definitionNoAnswer) "
                + "other-file \(score.definitionOtherFile) same-file-other-lines \(score.definitionSameFileOtherLines)",
            "differential \(name) rank buckets 1 | 2-3 | 4-8 | 9+ | absent | empty",
        ]
        let order: [JavaIdentifierRole?] = [.declared, .call, .member, .typeName, .imported, .plain, nil]
        for role in order {
            let label = role.map { "\($0)" } ?? "unknown"
            var counts = Array(repeating: 0, count: CompletionRankBucket.allCases.count)
            for detail in details where detail.role == role {
                let bucket = CompletionRankBucket(rank: detail.rank, empty: detail.empty)
                if let index = CompletionRankBucket.allCases.firstIndex(of: bucket) {
                    counts[index] += 1
                }
            }
            lines.append("differential \(name) [\(label)] \(counts.map(String.init).joined(separator: " / "))")
        }
        return lines.joined(separator: "\n")
    }

    static func verdict(
        site: IdentifierSite, symbol: JavaAnalysisSymbol, text: String, file: URL,
        world: World, roles: [Int: JavaIdentifierRole] = [:], sourceRoot: URL? = nil
    ) async -> Verdict {
        var verdict = Verdict()
        let prefix = String(site.name.prefix(prefixLength))
        verdict.siteRole = roles[site.startUTF16]
        verdict.siteDotted = isDotted(at: site.startUTF16, in: text)
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
            verdict.definitionCandidates = hits.count
            verdict.definitionAnswered = hits.contains { $0.url != nil }
            verdict.definitionMatched = hits.contains { hit in
                guard let url = hit.url else { return false }
                let line = hit.range.start.line + 1
                return sameFile(url.path, declarationFile) && line >= startLine && line <= endLine
            }
            if let root = sourceRoot {
                verdict.declarationInSource = URL(fileURLWithPath: declarationFile)
                    .resolvingSymlinksInPath().path
                    .hasPrefix(root.resolvingSymlinksInPath().path)
            }
            if verdict.definitionMatched {
                verdict.definitionOutcome = .matched
            } else if !verdict.definitionAnswered {
                verdict.definitionOutcome = .noAnswer
            } else if hits.contains(where: { $0.url.map { sameFile($0.path, declarationFile) } ?? false }) {
                verdict.definitionOutcome = .sameFileOtherLines
            } else {
                verdict.definitionOutcome = .otherFile
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

        // What typing would produce: the chars after the caret are those of the next identifier,
        // not the rest of this one. The dummy repair sees the prefix as the whole typed word.
        let typedLength = min(prefixLength, site.name.utf16.count)
        let completionText = Self.completionBuffer(text: text, site: site, typedLength: typedLength)
        let caret = position(in: completionText, utf16: site.startUTF16 + typedLength)
        let prefixStart = position(in: completionText, utf16: site.startUTF16)
        let completing = document(url: file, text: completionText, caret: caret)
        let trigger = RequestTrigger.keystroke(String(prefix.suffix(1)))
        let items = await world.completion.provide(context: CompletionContext(
            document: completing,
            cursor: Cursor(position: caret),
            trigger: trigger,
            prefix: prefix,
            range: TextRange(start: prefixStart, end: caret)
        ))
        // The previous metric: raw provider order, for one revision.
        let legacyLabels = items.prefix(topK).map(\.label)
        verdict.legacyCompletionHit = legacyLabels.contains { $0 == symbol.name || $0.hasPrefix(symbol.name + "(") }
        // The popup's list: ranked, exactly as the engine and the controller rank it.
        let ranked = DefaultRanker(recency: CompletionRecency())
            .rankSynchronously(items: items, prefix: prefix)
        verdict.completionEmpty = items.isEmpty
        if let rank = ranked.firstIndex(where: {
            $0.item.label == symbol.name || $0.item.label.hasPrefix(symbol.name + "(")
        }) {
            verdict.completionRank = rank + 1
            verdict.completionHit = rank < topK
        }
        let rankedLabels = ranked.prefix(topK).map(\.item.label)

        let hoverCaret = position(in: text, utf16: site.lastUTF16)
        let hovering = document(url: file, text: text, caret: hoverCaret)
        let hover = await world.hover.provide(context: HoverContext(
            document: hovering, cursor: Cursor(position: hoverCaret),
            selection: Selection(range: TextRange(start: hoverCaret, end: hoverCaret)),
            trigger: .manual
        ))
        verdict.hoverHit = hover?.contents.contains(symbol.name) == true
        verdict.hoverDefinitionHit = verdict.definitionMatched
        verdict.note += " completion [\(rankedLabels.joined(separator: ", "))] hover \(hover?.contents.contains(symbol.name) == true ? "yes" : "no")"
        return verdict
    }

    // MARK: - Site roles

    /// Maps each identifier token's start UTF-16 offset to its winning role, parsed once per file.
    static func roleMap(in text: String) -> [Int: JavaIdentifierRole] {
        guard let tree = JavaSyntaxParser().parse(text) else { return [:] }
        var map: [Int: JavaIdentifierRole] = [:]
        var stack = [tree.rootNode]
        while let node = stack.popLast() {
            if node.type == "identifier" || node.type == "type_identifier",
               let roles = JavaRoleExtractor.role(of: node),
               let primary = primaryRole(roles),
               let offset = utf16Offset(of: node.byteRange.lowerBound, in: text) {
                map[offset] = primary
            }
            stack.append(contentsOf: node.children)
        }
        return map
    }

    /// One tag per site: declarations first, then the use kinds. A method-reference qualifier
    /// union (`typeName` + `plain`) lands on `typeName`.
    static func primaryRole(_ roles: JavaIdentifierRoles) -> JavaIdentifierRole? {
        if roles.contains(.declared) { return .declared }
        if roles.contains(.call) { return .call }
        if roles.contains(.member) { return .member }
        if roles.contains(.typeName) { return .typeName }
        if roles.contains(.imported) { return .imported }
        if roles.contains(.plain) { return .plain }
        return nil
    }

    /// Whether a `.` precedes the site after optional whitespace (`foo.bar`, not a declaration).
    static func isDotted(at startUTF16: Int, in text: String) -> Bool {
        let ns = text as NSString
        var index = startUTF16 - 1
        while index >= 0 {
            let code = ns.character(at: index)
            if code == 0x2E { return true }
            if code == 0x20 || code == 0x09 || code == 0x0A || code == 0x0D { index -= 1; continue }
            return false
        }
        return false
    }

    /// The buffer a keystroke popup completes: the typed prefix plus whatever follows the
    /// identifier. With the caret mid-identifier (`fr|omJson`), the tail (`omJson`) is gone,
    /// so the repair sees what typing would produce instead of `fr__penumbra__omJson`.
    static func completionBuffer(text: String, site: IdentifierSite, typedLength: Int) -> String {
        (text as NSString).substring(to: site.startUTF16 + typedLength)
            + (text as NSString).substring(from: site.endUTF16)
    }

    static func utf16Offset(of byteOffset: Int, in text: String) -> Int? {
        guard let index = text.utf8.index(text.utf8.startIndex, offsetBy: byteOffset, limitedBy: text.utf8.endIndex),
              let mapped = index.samePosition(in: text.utf16) else { return nil }
        return text.utf16.distance(from: text.utf16.startIndex, to: mapped)
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

    /// Sums per-project bucket arrays (in `CompletionRankBucket` order) into one printable line.
    static func bucketLine(_ all: [[Int]]) -> String {
        let width = CompletionRankBucket.allCases.count
        var totals = Array(repeating: 0, count: width)
        for buckets in all {
            for (index, count) in buckets.prefix(width).enumerated() {
                totals[index] += count
            }
        }
        return totals.map(String.init).joined(separator: " / ")
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
