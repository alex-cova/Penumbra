import EditorIntelligence
import Foundation

/// Candidate source that asks the name index about roots it has a loaded shard for, and scans the
/// rest of the roots on disk, so Find Usages works before (or without) an index.
struct JavaIndexedOrScanningCandidates: JavaUsageCandidateSource {
    let nameIndex: JavaNameIndex?
    let scan: JavaTextScanCandidateSource

    func candidateFiles(containing identifier: String, in roots: [URL]) async -> [URL] {
        guard let nameIndex else { return await scan.candidateFiles(containing: identifier, in: roots) }
        var indexed: [URL] = []
        var unindexed: [URL] = []
        for root in roots {
            if await nameIndex.indexedFileCount(in: root) != nil {
                indexed.append(root)
            } else {
                unindexed.append(root)
            }
        }
        var found = Set<String>()
        if !indexed.isEmpty {
            for url in await nameIndex.candidateFiles(containing: identifier, in: indexed) { found.insert(url.standardizedFileURL.path) }
        }
        if !unindexed.isEmpty {
            for url in await scan.candidateFiles(containing: identifier, in: unindexed) { found.insert(url.standardizedFileURL.path) }
        }
        return found.sorted().map { URL(fileURLWithPath: $0) }
    }
}

/// Find Usages for Java: resolves the symbol at the caret to a ``JavaSymbolID`` and lists every
/// place the project binds to it. Runs as a primary provider for `.references`; locals are
/// answered in-file, everything else through ``JavaUsageSearch`` (one search per member of a
/// method's override family, results merged). Declarations are not listed.
public actor JavaFindUsagesProvider: NavigationProvider {
    public let name = "JavaFindUsages"
    private let index: JavaIndex
    private let indexPaths: JavaIndexPaths
    private let nameIndex: JavaNameIndex?
    private var roots: [URL] = []
    private var classpathModel: JavaGradleProjectModel?
    private var jdkHome: URL?
    private var openBuffer: (@Sendable (URL) async -> String?)?

    public init(index: JavaIndex, indexPaths: JavaIndexPaths, nameIndex: JavaNameIndex? = nil) {
        self.index = index
        self.indexPaths = indexPaths
        self.nameIndex = nameIndex
    }

    /// The project's source roots (or files) searched for usages. Empty means only the file at the caret.
    public func setProjectRoots(_ roots: [URL]) {
        self.roots = roots
    }

    public func setSourceSetClasspath(_ model: JavaGradleProjectModel?, indexPaths: JavaIndexPaths) {
        classpathModel = model
    }

    public func setJDKHome(_ home: URL?) {
        jdkHome = home
    }

    public func setOpenBufferLookup(_ lookup: (@Sendable (URL) async -> String?)?) {
        openBuffer = lookup
    }

    public nonisolated func isPrimary(for context: NavigationContext) -> Bool {
        context.kind == .references && context.document.languageIdentifier == "java"
    }

    public func provide(context: NavigationContext) async -> NavigationResult? {
        guard context.kind == .references, context.document.languageIdentifier == "java" else { return nil }
        let source = JavaNavigationText.fullText(of: context.document)
        guard !source.isEmpty else { return nil }
        let usages = await findUsages(source: source, url: context.document.url, utf16Offset: context.cursor.position.utf16Offset)
        return Self.result(for: usages, document: context.document)
    }

    /// Usages (declarations excluded) of the symbol at `utf16Offset`, sorted by file then position.
    public func findUsages(source: String, url: URL?, utf16Offset: Int) async -> [JavaUsage] {
        let environment = JavaReferenceEnvironment(
            index: index, jdkHome: jdkHome, cacheRoot: indexPaths.root, openBuffer: openBuffer,
            gradleModel: classpathModel, indexPaths: classpathModel == nil ? nil : indexPaths
        )
        guard let id = await JavaSymbolIdentity.symbolID(at: utf16Offset, in: source, url: url, environment: environment) else {
            return []
        }
        var all: [JavaUsage]
        if case .local = id {
            all = JavaLocalUsages.usages(of: id, in: source)
        } else {
            let searchRoots = roots.isEmpty ? (url.map { [$0] } ?? []) : roots
            let scan = JavaTextScanCandidateSource(textProvider: openBuffer, extraFiles: url.map { [$0] } ?? [])
            let candidates = JavaIndexedOrScanningCandidates(nameIndex: nameIndex, scan: scan)
            var targets = [id]
            if let file = url {
                let scope = environment.queryScope(for: file)
                let reader = openBuffer
                targets = await JavaIndex.$queryScope.withValue(scope) {
                    await JavaMemberLookup.$sourceTextProvider.withValue(reader) {
                        await self.familyIDs(of: id)
                    }
                }
            }
            var seen = Set<String>()
            all = []
            for target in targets {
                if Task.isCancelled { return [] }
                let found = await JavaUsageSearch.collect(
                    target, candidates: candidates, roots: searchRoots, environment: environment, includeDeclarations: false
                )
                for usage in found where seen.insert("\(usage.url.standardizedFileURL.path):\(usage.byteRange.lowerBound)").inserted {
                    all.append(usage)
                }
            }
        }
        return all.filter { $0.kind != .declaration }.sorted {
            if $0.url.path != $1.url.path { return $0.url.path < $1.url.path }
            return $0.byteRange.lowerBound < $1.byteRange.lowerBound
        }
    }

    private func familyIDs(of id: JavaSymbolID) async -> [JavaSymbolID] {
        await JavaMethodFamily.symbolIDs(of: id, index: index)
    }

    static func kindLabel(_ kind: JavaUsage.Kind) -> String {
        switch kind {
        case .declaration: return "declaration"
        case .read: return "read"
        case .write: return "write"
        case .call: return "call"
        case .typeReference: return "type"
        case .import: return "import"
        case .constructorCall: return "new"
        case .methodReference: return "method ref"
        }
    }

    static func result(for usages: [JavaUsage], document: Document) -> NavigationResult? {
        let locations = usages.map { usage -> Location in
            let same = JavaNavigationText.sameFile(usage.url, document.url)
            let end = usage.utf16Range.location + usage.utf16Range.length
            let range = TextRange(
                start: TextPosition(line: usage.line, column: usage.column, utf16Offset: usage.utf16Range.location),
                end: TextPosition(line: usage.line, column: usage.column + usage.utf16Range.length, utf16Offset: end)
            )
            return Location(
                documentID: same ? document.id : DocumentID(),
                url: usage.url,
                range: range,
                displayName: "\(usage.url.lastPathComponent):\(usage.line + 1)",
                usage: Location.UsageInfo(
                    kindLabel: kindLabel(usage.kind), isAmbiguous: usage.confidence == .ambiguous,
                    lineText: usage.lineText, matchRange: NSRange(location: usage.column, length: usage.utf16Range.length),
                    line: usage.line
                )
            )
        }
        switch locations.count {
        case 0: return nil
        case 1: return .single(locations[0])
        default: return .multiple(locations)
        }
    }
}
