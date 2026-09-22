import EditorIntelligence
import Foundation
import JavaIntelligence

/// Owns Java code intelligence for the workspace: the shared `JavaIndex` (JDK + open project's
/// source tree), the `JavaOverlayService` keeping it in sync with open/edited documents, and the
/// background indexing that populates it. `IDEIntelligenceServices` holds one instance and feeds
/// its index into `JavaCompletionProvider`; `IDEWorkspace` drives it (connect on bootstrap, retarget
/// on `applyProjectRoot`).
///
/// Indexing runs in two independent, recombined pieces so opening/closing a project folder never
/// has to touch the (potentially large, slow-to-rebuild) JDK shard: the JDK is indexed once at
/// bootstrap and its reader kept for the app's lifetime; a project's `.java` tree is indexed
/// whenever the project root changes, replacing only the project-scoped source of `javaIndex`.
@MainActor
final class IDEJavaSupport {
    let javaIndex = JavaIndex()
    let overlayService: JavaOverlayService
    let completionProvider: JavaCompletionProvider

    private let paths = JavaIndexPaths.default()
    private let scheduler = JavaIndexScheduler()
    private var jdkReader: JavaIndexShardReader?
    private var projectReader: JavaIndexShardReader?
    private var jdkIndexingTask: Task<Void, Never>?
    private var projectIndexingTask: Task<Void, Never>?

    /// A short, human-readable status for the status bar ("Indexing JDK 24...", "Indexing project
    /// sources...", or nil once idle). `IDEWorkspace`/`IDEStatusBarPanel` can poll or observe this
    /// once wired up; not yet surfaced in the UI (a follow-up -- see the handoff plan's Umbra
    /// integration section).
    private(set) var statusMessage: String?

    init() {
        overlayService = JavaOverlayService(index: javaIndex)
        completionProvider = JavaCompletionProvider(index: javaIndex)
    }

    /// Connects the overlay service to the shared workspace (mirrors
    /// `IndexingService.connect(to:)`) and kicks off JDK indexing in the background. Call once,
    /// from `IDEWorkspace.bootstrap()`.
    @discardableResult
    func connect(to workspace: Workspace) async -> Task<Void, Never> {
        let task = await overlayService.connect(to: workspace)
        indexJDK()
        return task
    }

    /// Re-targets project-source indexing at a new folder (or clears it when `url` is `nil`, e.g.
    /// the user closes the folder). Safe to call repeatedly; a new call cancels any indexing still
    /// in flight for the previous root.
    func setProjectRoot(_ url: URL?) {
        projectIndexingTask?.cancel()
        guard let url else {
            projectReader = nil
            Task { await publishSources() }
            return
        }
        projectIndexingTask = Task { [paths, scheduler] in
            let root = SourceRoot(directory: url)
            let shardURL = paths.projectSourcesShard(for: url)
            statusMessage = "Indexing project sources…"
            for await _ in await scheduler.index([(root: root, shardURL: shardURL)]) {}
            guard !Task.isCancelled else { return }
            projectReader = try? JavaIndexShardReader(url: shardURL)
            statusMessage = nil
            await publishSources()
        }
    }

    private func indexJDK() {
        jdkIndexingTask?.cancel()
        jdkIndexingTask = Task { [paths, scheduler] in
            // JDKLocator.select() does synchronous filesystem/process work (java_home -X, walking
            // ~/Library/Java/JavaVirtualMachines); hopped off the main actor so it can't stall the
            // UI during app launch.
            let installation = await Task.detached(priority: .utility) { JDKLocator().select() }.value
            guard let installation else {
                statusMessage = nil
                return
            }
            let root = JDKCtSymRoot(installation: installation)
            let shardURL = paths.jdkShard(installation, kind: "ctsym")
            statusMessage = "Indexing JDK \(installation.featureVersion)…"
            for await _ in await scheduler.index([(root: root, shardURL: shardURL)]) {}
            guard !Task.isCancelled else { return }
            jdkReader = try? JavaIndexShardReader(url: shardURL)
            statusMessage = nil
            await publishSources()
        }
    }

    private func publishSources() async {
        var sources: [JavaIndex.Source] = []
        if let jdkReader { sources.append(.init(precedence: 3, reader: jdkReader)) }
        if let projectReader { sources.append(.init(precedence: 1, reader: projectReader)) }
        await javaIndex.setSources(sources)
    }
}
