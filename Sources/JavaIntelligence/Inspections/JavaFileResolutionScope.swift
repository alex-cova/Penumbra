import Foundation

/// What one file resolves against: the shards its module sees, the shards that must be loaded
/// before it can call a class missing, and its JPMS visibility. The live `JavaInspectionService`
/// and the batch `JavaBatchInspector` both get a file's context here, so a file is judged the
/// same way in the editor and in Inspect Code.
public struct JavaFileResolutionContext: Sendable, Equatable {
    /// ``JavaIndex/queryScope``: the shards the file's source set sees; `nil` sees all.
    public let visibleShards: Set<String>?
    /// ``JavaIndex/requiredShards``: the visible shards the model indexes into.
    public let requiredShards: Set<String>?
    /// ``JavaIndex/queryModules``.
    public let modules: JavaModuleVisibility?

    public static let unscoped = JavaFileResolutionContext(visibleShards: nil, requiredShards: nil, modules: nil)

    public init(visibleShards: Set<String>?, requiredShards: Set<String>?, modules: JavaModuleVisibility?) {
        self.visibleShards = visibleShards
        self.requiredShards = requiredShards
        self.modules = modules
    }

    /// Runs `body` with the three task-locals the index reads, in the caller's isolation (as
    /// `TaskLocal.withValue` does), so an actor can pass a closure that touches its own state.
    public func apply<T>(isolation: isolated (any Actor)? = #isolation, _ body: () async -> T) async -> T {
        await JavaIndex.$queryScope.withValue(visibleShards) {
            await JavaIndex.$requiredShards.withValue(requiredShards) {
                await JavaIndex.$queryModules.withValue(modules) {
                    await body()
                }
            }
        }
    }
}

/// Builds each file's ``JavaFileResolutionContext`` from a module model. Without a model every
/// file is unscoped (a plain folder: one whole-tree shard).
public struct JavaFileResolutionScopes: Sendable, Equatable {
    public let model: JavaGradleProjectModel?
    private let paths: JavaIndexPaths?
    /// Shard paths the model's roots are indexed into (existing source directories and jars). A
    /// file's required shards are its scope narrowed to these: the scope also names directories
    /// that never get a shard of their own (a generated directory inside a source one).
    private let indexedShardPaths: Set<String>

    public static let none = JavaFileResolutionScopes(model: nil, paths: nil)

    /// Reads which source directories exist: call it when the model changes, not per file.
    public init(model: JavaGradleProjectModel?, paths: JavaIndexPaths?) {
        guard let model, let paths else {
            self.model = nil
            self.paths = nil
            indexedShardPaths = []
            return
        }
        self.model = model
        self.paths = paths
        let targets = model.sourceIndexTargets(paths: paths) + model.jarIndexTargets(paths: paths)
        indexedShardPaths = Set(targets.map(\.shardURL.path))
    }

    public func context(for file: URL) -> JavaFileResolutionContext {
        guard let model, let paths else { return .unscoped }
        let visible = model.visibleShardPaths(forFile: file, paths: paths)
        return JavaFileResolutionContext(
            visibleShards: visible,
            requiredShards: visible.map { $0.intersection(indexedShardPaths) },
            modules: model.moduleVisibility(forFile: file, paths: paths)
        )
    }

    public static func == (lhs: JavaFileResolutionScopes, rhs: JavaFileResolutionScopes) -> Bool {
        lhs.model == rhs.model && lhs.paths?.root == rhs.paths?.root
    }
}
