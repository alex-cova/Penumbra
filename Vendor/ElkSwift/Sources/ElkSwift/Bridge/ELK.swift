// ELK — public entry point for the native Swift layout engine.
// Pure Swift port of Eclipse Layout Kernel (Java).

import Foundation
import os

public final class ELK {

    public enum Error: Swift.Error, LocalizedError {
        case runtimeError(String)
        case invalidResult
        case timedOut(TimeInterval)

        public var errorDescription: String? {
            switch self {
            case .runtimeError(let message):
                return "ELK layout error: \(message)"
            case .invalidResult:
                return "ELK returned an invalid graph"
            case .timedOut(let timeout):
                return "ELK layout timed out after \(timeout)s"
            }
        }
    }

    private let engine: RecursiveGraphLayoutEngine

    /// Whether the layered algorithm has been registered.
    private nonisolated(unsafe) static var _algorithmsRegistered = false
    private static let _registrationLock: os_unfair_lock_t = {
        let lock = os_unfair_lock_t.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        return lock
    }()

    public init() {
        engine = RecursiveGraphLayoutEngine()
        ELK.registerAlgorithmsIfNeeded()
    }

    /// Register the layered layout algorithm with the metadata service.
    private static func registerAlgorithmsIfNeeded() {
        os_unfair_lock_lock(_registrationLock)
        defer { os_unfair_lock_unlock(_registrationLock) }
        guard !_algorithmsRegistered else { return }
        _algorithmsRegistered = true

        let service = LayoutMetaDataService.getInstance()

        // Register the layered algorithm
        let layeredData = LayoutAlgorithmData.Builder()
            .id("org.eclipse.elk.layered")
            .name("ELK Layered")
            .providerFactory(LayoutProviderFactory(provider: { LayeredLayoutProvider() }))
            .supportedFeatures([
                .selfLoops,
                .insideSelfLoops,
                .multiEdges,
                .edgeLabels,
                .ports,
                .compound,
                .clusters
            ])
            .create()

        service.registerAlgorithm(layeredData)
    }

    /// Layout a graph specified as a JSON-compatible dictionary.
    public func layout(
        graph: [String: Any],
        options: [String: Any]? = nil,
        timeout: TimeInterval = 30
    ) throws -> [String: Any] {
        // 1. Import: [String: Any] → ElkNode
        let importer = JsonImporter()
        let elkGraph = importer.transform(graph)

        // 2. Merge top-level options if provided
        if let options = options {
            for (key, value) in options {
                elkGraph.setProperty(key, value)
            }
        }

        // 3. Run layout
        let monitor = TimeoutProgressMonitor(timeout: timeout)
        try engine.layout(layoutGraph: elkGraph, progressMonitor: monitor)
        if monitor.isCanceled() {
            throw Error.timedOut(timeout)
        }

        // 4. Export: ElkNode → [String: Any]
        let exporter = JsonExporter()
        return exporter.export(elkGraph)
    }
}

// MARK: - Layout Provider Factory

/// Simple IFactory implementation that creates layout provider instances.
private class LayoutProviderFactory: IFactory {
    private let createFn: () -> AbstractLayoutProvider

    init(provider: @escaping () -> AbstractLayoutProvider) {
        self.createFn = provider
    }

    func create() -> Any {
        return createFn()
    }

    func destroy(_ obj: Any) {
        // No-op: layout providers don't hold external resources.
    }
}
