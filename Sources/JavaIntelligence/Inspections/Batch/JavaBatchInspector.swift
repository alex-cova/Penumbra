import EditorIntelligence
import Foundation

/// Inspects many files outside the on-the-fly service, so a project-wide run never queues behind
/// (or ahead of) typing. Each file goes through the same ``JavaInspectionPipeline`` as the editor.
public struct JavaBatchInspector: Sendable {
    public struct Options: Sendable {
        public var profile: JavaInspectionProfile
        public var classifier: JavaInspectionFileClassifier
        /// Run only these rules (Run Inspection by Name), whatever the profile says; `nil` runs
        /// the profile's rules.
        public var onlyRules: Set<JavaInspectionRule>?
        /// The project-wide rules cost a usage search per declaration.
        public var includeProjectRules: Bool
        public var maxConcurrentFiles: Int

        public init(
            profile: JavaInspectionProfile,
            classifier: JavaInspectionFileClassifier = JavaInspectionFileClassifier(),
            onlyRules: Set<JavaInspectionRule>? = nil,
            includeProjectRules: Bool = false,
            maxConcurrentFiles: Int = 4
        ) {
            self.profile = profile
            self.classifier = classifier
            self.onlyRules = onlyRules
            self.includeProjectRules = includeProjectRules
            self.maxConcurrentFiles = max(1, maxConcurrentFiles)
        }
    }

    public enum Event: Sendable {
        case started(total: Int)
        /// Findings of one file; files with none are not reported.
        case file(URL, [JavaInspection])
        case progress(done: Int, total: Int)
        case finished(cancelled: Bool)
    }

    private let index: JavaIndex
    private let usageProvider: JavaFindUsagesProvider?
    private let queryScope: @Sendable (URL) -> Set<String>?

    /// - Parameter queryScope: the shard paths a file's source set sees (`nil` sees everything).
    public init(
        index: JavaIndex,
        usageProvider: JavaFindUsagesProvider? = nil,
        queryScope: @escaping @Sendable (URL) -> Set<String>? = { _ in nil }
    ) {
        self.index = index
        self.usageProvider = usageProvider
        self.queryScope = queryScope
    }

    /// - Parameter text: a file's current text, open buffer first, else the disk; `nil` skips it.
    public func run(
        files: [URL],
        options: Options,
        text: @escaping @Sendable (URL) async -> String?
    ) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let task = Task {
                let total = files.count
                continuation.yield(.started(total: total))
                var done = 0
                await withTaskGroup(of: (URL, [JavaInspection]).self) { group in
                    var iterator = files.makeIterator()
                    var running = 0
                    func addNext(_ group: inout TaskGroup<(URL, [JavaInspection])>) -> Bool {
                        guard let url = iterator.next() else { return false }
                        group.addTask { (url, await inspect(url: url, options: options, text: text)) }
                        return true
                    }
                    while running < options.maxConcurrentFiles, addNext(&group) { running += 1 }
                    while let (url, found) = await group.next() {
                        done += 1
                        if !found.isEmpty { continuation.yield(.file(url, found)) }
                        continuation.yield(.progress(done: done, total: total))
                        if Task.isCancelled {
                            group.cancelAll()
                            continue
                        }
                        _ = addNext(&group)
                    }
                }
                continuation.yield(.finished(cancelled: Task.isCancelled))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One file's findings, with suppression and the profile's severities applied. Findings set
    /// to "No highlighting" are included: Inspect Code reports them.
    public func inspect(
        url: URL,
        options: Options,
        text: @Sendable (URL) async -> String?
    ) async -> [JavaInspection] {
        guard !Task.isCancelled, let source = await text(url) else { return [] }
        let file = options.classifier.context(for: url)
        var enabled = options.profile.enabledRules(in: file)
        if let only = options.onlyRules { enabled = only }
        guard !enabled.isEmpty, let tree = JavaSyntaxParser().parse(source) else { return [] }
        let scope = queryScope(url)
        let profile = options.profile
        let thresholds = profile.thresholds
        let projectOptions = profile.projectOptions
        let runsProjectRules = options.includeProjectRules && !enabled.isDisjoint(with: JavaInspectionRegistry.projectRules)
        let provider = usageProvider
        let index = index
        let found: [JavaInspection] = await JavaIndex.$queryScope.withValue(scope) {
            var projectFindings: [JavaInspection] = []
            if runsProjectRules, let provider {
                projectFindings = await JavaProjectInspector.inspect(
                    source: source, url: url, tree: tree, provider: provider, enabled: enabled, options: projectOptions
                )
            }
            return await JavaInspectionPipeline.inspect(
                text: source, url: url, tree: tree, index: index,
                enabled: enabled, thresholds: thresholds, projectFindings: projectFindings
            )
        }
        guard !Task.isCancelled else { return [] }
        let outcome = JavaInspectionPipeline.finalize(found, text: source, profile: profile, file: file)
        return outcome.visible + outcome.quiet
    }
}
