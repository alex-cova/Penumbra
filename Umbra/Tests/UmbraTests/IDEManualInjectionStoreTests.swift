import Foundation
import XCTest
@testable import Umbra

/// F-11: per-document injection providers are cached in `IDEManualInjectionStore`, not on
/// `IDEWorkspace`. Identity stability across mode reconstructions, and removal on close.
@MainActor
final class IDEManualInjectionStoreTests: XCTestCase {
    func testProviderIsStablePerDocument() {
        let store = IDEManualInjectionStore()
        let id = UUID()
        let first = store.provider(forDocumentID: id, url: nil, displayName: "scratch")
        let second = store.provider(forDocumentID: id, url: nil, displayName: "scratch")
        XCTAssertTrue(first === second, "mode reconstructions must keep feeding the same instance")

        let other = store.provider(forDocumentID: UUID(), url: nil, displayName: "scratch")
        XCTAssertFalse(other === first)
    }

    func testRemovalDropsTheCachedProvider() {
        let store = IDEManualInjectionStore()
        let id = UUID()
        let before = store.provider(forDocumentID: id, url: nil, displayName: "scratch")
        store.removeDocument(id)
        let after = store.provider(forDocumentID: id, url: nil, displayName: "scratch")
        XCTAssertFalse(after === before)
        // Removing twice answers quietly.
        store.removeDocument(id)
    }
}
