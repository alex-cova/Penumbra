import EditorIntelligence
import XCTest

/// F12. The long-lived `for await` loops the workspace services start must not keep their owners
/// alive once everything else has let go.
final class WorkspaceTeardownTests: XCTestCase {
    /// An adapter whose event stream never ends on its own, like `PenumbraEditorAdapter`'s.
    private final class OpenEndedAdapter: EditorAdapter, @unchecked Sendable {
        let id = EditorAdapterID()
        let context = EditorContext()
        let events: AsyncStream<EditorEvent>
        private let continuation: AsyncStream<EditorEvent>.Continuation
        init() { (events, continuation) = AsyncStream<EditorEvent>.makeStream() }
        var currentDocument: Document? { nil }
        var openDocuments: [Document] { [] }
        func document(withID id: DocumentID) -> Document? { nil }
        func applyEdit(_ edit: TextEdit, toDocumentWithID documentID: DocumentID) async throws {}
        func focusRange(_ range: EditorIntelligence.TextRange, inDocumentWithID documentID: DocumentID) async throws {}
    }

    private struct NoOpParser: LanguageParser {
        func parse(document: Document) async -> SyntaxTree { EmptyTree() }
        struct EmptyTree: SyntaxTree {
            var symbols: [Symbol] { [] }
            var words: [String] { [] }
            var imports: [String] { [] }
        }
    }

    private final class IdleWatcher: FileSystemWatcher, @unchecked Sendable {
        let events: AsyncStream<FileSystemEvent>
        private let continuation: AsyncStream<FileSystemEvent>.Continuation
        init() { (events, continuation) = AsyncStream<FileSystemEvent>.makeStream() }
        func start() async {}
        func stop() async {}
    }

    /// Spins the cooperative pool until `condition` holds or a second passes.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0 ..< 100 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    func testWorkspaceIsReleasedAfterItsAdapterAndOwnerLetGo() async {
        weak var weakWorkspace: Workspace?
        weak var weakAdapter: OpenEndedAdapter?
        do {
            let workspace = Workspace()
            let adapter = OpenEndedAdapter()
            weakWorkspace = workspace
            weakAdapter = adapter
            await workspace.connect(to: adapter)
            await Task.yield()
        }
        let released = await eventually { weakWorkspace == nil && weakAdapter == nil }
        XCTAssertTrue(released, "workspace alive: \(weakWorkspace != nil), adapter alive: \(weakAdapter != nil)")
    }

    func testWorkspaceIsReleasedAfterItsWatcherAndOwnerLetGo() async {
        weak var weakWorkspace: Workspace?
        weak var weakWatcher: IdleWatcher?
        do {
            let workspace = Workspace()
            let watcher = IdleWatcher()
            weakWorkspace = workspace
            weakWatcher = watcher
            await workspace.setFileSystemWatcher(watcher)
            await Task.yield()
        }
        let released = await eventually { weakWorkspace == nil && weakWatcher == nil }
        XCTAssertTrue(released, "workspace alive: \(weakWorkspace != nil), watcher alive: \(weakWatcher != nil)")
    }

    func testIndexingServiceIsReleasedAfterItsWorkspaceLetsGo() async {
        weak var weakService: IndexingService?
        weak var weakWorkspace: Workspace?
        do {
            let workspace = Workspace()
            let service = IndexingService(parser: NoOpParser())
            weakService = service
            weakWorkspace = workspace
            await service.connect(to: workspace)
            await Task.yield()
        }
        let released = await eventually { weakService == nil && weakWorkspace == nil }
        XCTAssertTrue(released, "service alive: \(weakService != nil), workspace alive: \(weakWorkspace != nil)")
    }

    func testSyncBridgeIsReleasedAfterItsWorkspaceLetsGo() async {
        weak var weakBridge: LSPWorkspaceSyncBridge?
        weak var weakWorkspace: Workspace?
        do {
            let workspace = Workspace()
            let bridge = LSPWorkspaceSyncBridge()
            weakBridge = bridge
            weakWorkspace = workspace
            await bridge.connect(to: workspace)
            await Task.yield()
        }
        let released = await eventually { weakBridge == nil && weakWorkspace == nil }
        XCTAssertTrue(released, "bridge alive: \(weakBridge != nil), workspace alive: \(weakWorkspace != nil)")
    }

    /// What a window builds: one workspace connected to an editor adapter, with the index and the
    /// sync bridge following the workspace. Dropping the window's references frees all of it.
    func testAWindowsWorthOfServicesIsReleasedTogether() async {
        weak var weakWorkspace: Workspace?
        weak var weakAdapter: OpenEndedAdapter?
        weak var weakIndexing: IndexingService?
        weak var weakBridge: LSPWorkspaceSyncBridge?
        do {
            let workspace = Workspace()
            let adapter = OpenEndedAdapter()
            let indexing = IndexingService(parser: NoOpParser())
            let bridge = LSPWorkspaceSyncBridge()
            weakWorkspace = workspace
            weakAdapter = adapter
            weakIndexing = indexing
            weakBridge = bridge
            await workspace.connect(to: adapter)
            await indexing.connect(to: workspace)
            await bridge.connect(to: workspace)
            await workspace.setFileSystemWatcher(IdleWatcher())
            await Task.yield()
        }
        let released = await eventually {
            weakWorkspace == nil && weakAdapter == nil && weakIndexing == nil && weakBridge == nil
        }
        XCTAssertTrue(
            released,
            "workspace: \(weakWorkspace != nil), adapter: \(weakAdapter != nil), indexing: \(weakIndexing != nil), bridge: \(weakBridge != nil)"
        )
    }

    /// `disconnect()` ends the loops while the objects are still referenced: events sent afterwards
    /// reach nobody.
    func testDisconnectStopsTheServicesFollowingTheWorkspace() async throws {
        let workspace = Workspace()
        let indexing = IndexingService(parser: NoOpParser())
        let task = await indexing.connect(to: workspace)
        await indexing.disconnect()
        _ = await task.value // returns: the loop saw the cancellation instead of waiting forever
        XCTAssertTrue(task.isCancelled)

        let adapter = OpenEndedAdapter()
        let adapterTask = await workspace.connect(to: adapter)
        await workspace.disconnect()
        _ = await adapterTask.value
        XCTAssertTrue(adapterTask.isCancelled)
    }
}
