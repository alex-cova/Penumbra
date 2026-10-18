import Foundation

final class TreeSitterLanguageLayerStore {
    var allIDs: [UnsafeRawPointer] {
        defer {
            semaphore.signal()
        }
        semaphore.wait()
        return Array(store.keys)
    }

    var allLayers: [TreeSitterLanguageLayer] {
        defer {
            semaphore.signal()
        }
        semaphore.wait()
        return Array(store.values) + Array(manualStore.values)
    }

    var isEmpty: Bool {
        defer {
            semaphore.signal()
        }
        semaphore.wait()
        return store.isEmpty
    }

    private var store: [UnsafeRawPointer: TreeSitterLanguageLayer] = [:]
    /// Manual injection layers, keyed by an opaque stable-ish label. Never mixed into the
    /// node-keyed `store`: a manual range has no tree-sitter node, so it cannot reuse that key,
    /// and query-driven pruning must never drop a manual layer.
    private var manualStore: [String: TreeSitterLanguageLayer] = [:]
    private let semaphore = DispatchSemaphore(value: 1)

    func storeLayer(_ layer: TreeSitterLanguageLayer, forKey key: UnsafeRawPointer) {
        defer {
            semaphore.signal()
        }
        semaphore.wait()
        store[key] = layer
    }

    func layer(forKey key: UnsafeRawPointer) -> TreeSitterLanguageLayer? {
        defer {
            semaphore.signal()
        }
        semaphore.wait()
        let value = store[key]
        return value
    }

    func removeLayer(forKey key: UnsafeRawPointer) {
        defer {
            semaphore.signal()
        }
        semaphore.wait()
        store.removeValue(forKey: key)
    }

    func removeAll() {
        defer {
            semaphore.signal()
        }
        semaphore.wait()
        store.removeAll()
    }

    func storeManualLayer(_ layer: TreeSitterLanguageLayer, forKey key: String) {
        defer {
            semaphore.signal()
        }
        semaphore.wait()
        manualStore[key] = layer
    }

    func manualLayer(forKey key: String) -> TreeSitterLanguageLayer? {
        defer {
            semaphore.signal()
        }
        semaphore.wait()
        return manualStore[key]
    }

    func removeManualLayer(forKey key: String) {
        defer {
            semaphore.signal()
        }
        semaphore.wait()
        manualStore.removeValue(forKey: key)
    }

    func removeAllManual() {
        defer {
            semaphore.signal()
        }
        semaphore.wait()
        manualStore.removeAll()
    }
}
