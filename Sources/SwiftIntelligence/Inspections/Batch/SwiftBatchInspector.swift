import EditorIntelligence
import Foundation

/// A finding with its editor position, which is what a results list and a fix need: ``SwiftInspection``
/// alone holds UTF-8 byte offsets into a text the list no longer has.
public struct SwiftLocatedInspection: Sendable, Hashable {
    public let inspection: SwiftInspection
    public let range: EditorIntelligence.TextRange

    public init(inspection: SwiftInspection, range: EditorIntelligence.TextRange) {
        self.inspection = inspection
        self.range = range
    }
}

extension SwiftLocatedInspection {
    /// The same diagnostic the editor shows for this finding, for a result row that opens its source.
    public func asDiagnostic() -> Diagnostic {
        Diagnostic(
            severity: inspection.severity.diagnosticSeverity, message: inspection.message, range: range,
            source: SwiftInspection.diagnosticSource, code: inspection.id
        )
    }
}

extension SwiftInspectionOptions {
    /// These options narrowed to exactly `rules` (Run Inspection by Name), whatever else is switched on;
    /// thresholds and severities are kept.
    public func only(_ rules: Set<SwiftInspectionRule>) -> SwiftInspectionOptions {
        var narrowed = self
        narrowed.disabled = []
        narrowed.enabled = []
        for rule in SwiftInspectionRule.allCases {
            let wanted = rules.contains(rule)
            if rule.isEnabledByDefault, !wanted { narrowed.disabled.insert(rule.code) }
            if !rule.isEnabledByDefault, wanted { narrowed.enabled.insert(rule.code) }
        }
        return narrowed
    }
}

/// Inspects many Swift files outside the editor's service, so a project-wide run never queues behind
/// typing. Each file goes through the same ``SwiftInspectionPipeline`` as the editor, so a rule behaves the
/// same in both. Not for a keystroke path: every file is parsed in full.
public struct SwiftBatchInspector: Sendable {
    public struct Options: Sendable {
        public var inspection: SwiftInspectionOptions
        /// Run only these rules, whatever `inspection` says; `nil` runs the enabled ones.
        public var onlyRules: Set<SwiftInspectionRule>?
        public var maxConcurrentFiles: Int
        /// The options for one file, when a profile's scopes make them differ per file; `inspection` is the base otherwise.
        public var optionsForFile: (@Sendable (URL) -> SwiftInspectionOptions)?
        /// Run the project-wide rules too (they ask the rest of the project, so they cost more per file).
        public var includeProjectRules: Bool
        /// Where the project-wide rules look names up; without it they do not run.
        public var projectLookup: (any SwiftProjectNameLookup)?

        public init(
            inspection: SwiftInspectionOptions, onlyRules: Set<SwiftInspectionRule>? = nil, maxConcurrentFiles: Int = 4,
            optionsForFile: (@Sendable (URL) -> SwiftInspectionOptions)? = nil,
            includeProjectRules: Bool = false, projectLookup: (any SwiftProjectNameLookup)? = nil
        ) {
            self.inspection = inspection
            self.onlyRules = onlyRules
            self.maxConcurrentFiles = max(1, maxConcurrentFiles)
            self.optionsForFile = optionsForFile
            self.includeProjectRules = includeProjectRules
            self.projectLookup = projectLookup
        }

        /// What the pipeline runs with.
        public var effective: SwiftInspectionOptions { onlyRules.map(inspection.only) ?? inspection }

        /// What the pipeline runs with for the file at `url`.
        public func effective(for url: URL) -> SwiftInspectionOptions {
            let base = optionsForFile?(url) ?? inspection
            return onlyRules.map(base.only) ?? base
        }
    }

    public enum Event: Sendable {
        case started(total: Int)
        /// Findings of one file; files with none are not reported.
        case file(URL, [SwiftLocatedInspection])
        case progress(done: Int, total: Int)
        case finished(cancelled: Bool)
    }

    public init() {}

    /// - Parameter text: a file's current text, open buffer first, else the disk; `nil` skips it.
    public func run(
        files: [URL], options: Options, text: @escaping @Sendable (URL) async -> String?
    ) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let task = Task {
                let total = files.count
                continuation.yield(.started(total: total))
                var done = 0
                await withTaskGroup(of: (URL, [SwiftLocatedInspection]).self) { group in
                    var iterator = files.makeIterator()
                    var running = 0
                    func addNext(_ group: inout TaskGroup<(URL, [SwiftLocatedInspection])>) -> Bool {
                        guard let url = iterator.next() else { return false }
                        group.addTask { (url, await Self.inspect(url: url, options: options, text: text)) }
                        return true
                    }
                    while running < options.maxConcurrentFiles, addNext(&group) { running += 1 }
                    while let (url, found) = await group.next() {
                        if Task.isCancelled { group.cancelAll() }
                        done += 1
                        if !found.isEmpty { continuation.yield(.file(url, found)) }
                        continuation.yield(.progress(done: done, total: total))
                        if !Task.isCancelled { _ = addNext(&group) }
                    }
                }
                continuation.yield(.finished(cancelled: Task.isCancelled))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One file's findings, in source order.
    public func inspect(url: URL, options: Options, text: @Sendable (URL) async -> String?) async -> [SwiftLocatedInspection] {
        await Self.inspect(url: url, options: options, text: text)
    }

    private static func inspect(url: URL, options: Options, text: @Sendable (URL) async -> String?) async -> [SwiftLocatedInspection] {
        guard !Task.isCancelled, let source = await text(url) else { return [] }
        let effective = options.effective(for: url)
        guard options.includeProjectRules, let lookup = options.projectLookup, effective.isEnabled(.unusedDeclaration),
              source.utf8.count <= SwiftInspectionService.maximumUTF8Length else {
            return located(in: source, effectiveOptions: effective)
        }
        let analysis = await SwiftInspectionPipeline.analyze(
            text: source, options: effective, url: url, isTest: SwiftInspectionScope.isTest(url), lookup: lookup,
            cache: SwiftSyntaxParseCache(capacity: 1)
        )
        return analysis.findings.map { SwiftLocatedInspection(inspection: $0, range: analysis.map.range(bytes: $0.bytes)) }
    }

    /// The findings of `source` under `options`.
    public static func located(in source: String, options: Options) -> [SwiftLocatedInspection] {
        located(in: source, effectiveOptions: options.effective)
    }

    public static func located(in source: String, effectiveOptions: SwiftInspectionOptions) -> [SwiftLocatedInspection] {
        guard source.utf8.count <= SwiftInspectionService.maximumUTF8Length else { return [] }
        // A cache of one: a run reads each file once, and the editor's cache keeps the open files.
        let analysis = SwiftInspectionPipeline.analyze(
            text: source, options: effectiveOptions, cache: SwiftSyntaxParseCache(capacity: 1)
        )
        return analysis.findings.map { SwiftLocatedInspection(inspection: $0, range: analysis.map.range(bytes: $0.bytes)) }
    }
}
