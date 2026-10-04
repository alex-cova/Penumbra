import Foundation
import LocalModelStore
import MLX
import MLXLLM
import MLXLMCommon

/// The one place model weights live. Weights take gigabytes, so the app holds a single loaded model
/// (`LocalModelRuntime.shared`) and every window's client queues behind it. Releasing every
/// reference is the only way to give the memory back.
public actor LocalModelRuntime {
    public static let shared = LocalModelRuntime()

    public struct Loaded: Sendable {
        public let model: InstalledLocalModel
        public let info: MLXModelInfo
        let container: ModelContainer
    }

    public private(set) var loaded: Loaded?
    /// Unload after this long unused. `nil` keeps the model until told otherwise.
    public var idleTimeout: Duration? = .seconds(30 * 60)

    private var loading: (id: String, task: Task<Loaded, Error>)?
    private var uses = 0
    private var idleTask: Task<Void, Never>?

    /// Extra folders to look for the Metal library in, for hosts whose resources are elsewhere
    /// (a test runner). The app needs none.
    nonisolated(unsafe) public static var extraMetalSearchRoots: [URL] = []

    public init() {}

    public func setIdleTimeout(_ timeout: Duration?) {
        idleTimeout = timeout
        scheduleIdleUnload()
    }

    /// Loads the model if it is not already the loaded one, replacing whatever was loaded.
    ///
    /// Goes through `LLMModelFactory.shared.loadContainer(from:using:)` and never
    /// `loadModelContainer(...)`: that one finds the factory with `NSClassFromString`, which a
    /// release link may strip because nothing else references `MLXLLM`.
    @discardableResult
    public func load(_ model: InstalledLocalModel) async throws -> Loaded {
        try Self.requireAvailable()
        if let loaded, loaded.model.id == model.id { return loaded }
        if let loading, loading.id == model.id { return try await loading.task.value }

        loading?.task.cancel()
        let directory = model.directory
        let task = Task { () -> Loaded in
            let container = try await LLMModelFactory.shared.loadContainer(from: directory, using: TokenizerBridgeLoader())
            return Loaded(model: model, info: MLXModelInspector.inspect(directory: directory), container: container)
        }
        loading = (model.id, task)
        do {
            let result = try await task.value
            // A newer request may have replaced this one while it loaded.
            guard loading?.id == model.id else { throw CancellationError() }
            loading = nil
            // Drop the old weights before holding the new ones where the caller can see them.
            if loaded != nil { unloadNow() }
            loaded = result
            scheduleIdleUnload()
            return result
        } catch {
            if loading?.id == model.id { loading = nil }
            if error is CancellationError { throw error }
            throw LocalModelError.loadFailed(error.localizedDescription)
        }
    }

    /// Marks the loaded model in use, so the idle timeout cannot free it mid-generation. Pair with `release()`.
    public func acquire(_ model: InstalledLocalModel) async throws -> Loaded {
        let result = try await load(model)
        uses += 1
        idleTask?.cancel()
        return result
    }

    public func release() {
        uses = max(0, uses - 1)
        scheduleIdleUnload()
    }

    public func unload() {
        loading?.task.cancel()
        loading = nil
        unloadNow()
    }

    /// MLX's allocations (weights, KV caches and the buffer cache), in bytes.
    public func memoryBytes() -> Int {
        guard MLXAvailability.currentStatus() == .available else { return 0 }
        return Memory.activeMemory + Memory.cacheMemory
    }

    // MARK: - Private

    private func unloadNow() {
        idleTask?.cancel()
        idleTask = nil
        loaded = nil
        if MLXAvailability.currentStatus() == .available { Memory.clearCache() }
    }

    private func scheduleIdleUnload() {
        idleTask?.cancel()
        idleTask = nil
        guard loaded != nil, uses == 0, let idleTimeout else { return }
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: idleTimeout)
            guard !Task.isCancelled else { return }
            await self?.unloadIfIdle()
        }
    }

    private func unloadIfIdle() {
        if uses == 0 { unloadNow() }
    }

    private static func requireAvailable() throws {
        // Point MLX at its kernels before anything touches the GPU; it cannot recover from not finding them.
        MLXMetalLibrary.install(extraRoots: Self.extraMetalSearchRoots)
        switch MLXAvailability.currentStatus() {
        case .available: return
        case .notAppleSilicon: throw LocalModelError.unsupportedHardware
        case .missingMetalLibrary: throw LocalModelError.loadFailed(MLXAvailability.message(for: .missingMetalLibrary))
        }
    }
}
