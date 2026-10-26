import EditorIntelligence
import Foundation
import Penumbra

/// In-memory temporary language injections (`Inject language…`, ⌥↩), keyed per document.
///
/// Comment (`language=ID`) injections need no storage — the comment itself persists — but
/// temporary injections live only until the document closes, so they stay in this store. Ranges
/// are UTF-16 document coordinates; the highlighter shifts its cached copy across edits and
/// writes it back here (`manualInjectionsDidShift`), so the store never goes stale between a
/// keystroke and the next full parse. Lock-protected: the layer pulls on background threads.
/// Lock-protected, so `@unchecked` is sound.
final class IDEManualInjectionStore: @unchecked Sendable {
    private let lock = NSLock()
    private var injectionsByKey: [String: [ManualLanguageInjection]] = [:]

    /// Store key for a document. Files key by URL; untitled buffers by display name.
    static func key(url: URL?, displayName: String) -> String {
        url?.absoluteString ?? "untitled:\(displayName)"
    }

    func injections(forKey key: String) -> [ManualLanguageInjection] {
        lock.withLock { injectionsByKey[key] ?? [] }
    }

    func addInjection(_ injection: ManualLanguageInjection, forKey key: String) {
        lock.withLock {
            var current = injectionsByKey[key] ?? []
            // One temporary per range: replacing keeps ⌥↩ from stacking duplicates.
            current.removeAll { $0.utf16Range == injection.utf16Range }
            current.append(injection)
            injectionsByKey[key] = current
        }
    }

    func setInjections(_ injections: [ManualLanguageInjection], forKey key: String) {
        lock.withLock { injectionsByKey[key] = injections }
    }

    func clear(forKey key: String) {
        _ = lock.withLock { injectionsByKey.removeValue(forKey: key) }
    }
}

/// Per-document ``ManualInjectionProviding`` over the shared store. Cached on the workspace (one
/// per open document) so mode reconstructions (`setLanguage`, inferred syntax) keep feeding the
/// same instance, and dropped when the document closes.
final class IDEManualInjectionProvider: ManualInjectionProviding {
    private let store: IDEManualInjectionStore
    private let key: String

    init(store: IDEManualInjectionStore, key: String) {
        self.store = store
        self.key = key
    }

    func manualInjections() -> [ManualLanguageInjection] {
        store.injections(forKey: key)
    }

    func manualInjectionsDidShift(_ injections: [ManualLanguageInjection]) {
        store.setInjections(injections, forKey: key)
    }
}
