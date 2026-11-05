import Foundation
import XCTest
@testable import Umbra

/// F-11: the diagram tab registry lives in its own owner, not on `IDEWorkspace`.
/// Register, lookup, removal, close-all and the class/module reload filter, without a window.
@MainActor
final class IDEDiagramSessionStoreTests: XCTestCase {
    private func makeSession(_ request: IDEDiagramRequest) -> IDEDiagramSession {
        IDEDiagramSession(
            request: request,
            settings: IDEDiagramSettings(),
            defaults: UserDefaults(suiteName: "umbra.diagram.store.tests.\(UUID().uuidString)") ?? .standard
        )
    }

    func testRegisterLookupAndRemove() {
        let store = IDEDiagramSessionStore()
        XCTAssertTrue(store.isEmpty)
        let id = UUID()
        XCTAssertNil(store.session(for: id))

        let session = makeSession(.classes(.project))
        store.register(session, for: id)
        XCTAssertFalse(store.isEmpty)
        XCTAssertTrue(store.session(for: id) === session)

        XCTAssertTrue(store.removeSession(for: id) === session)
        XCTAssertNil(store.session(for: id))
        XCTAssertTrue(store.isEmpty)
        XCTAssertNil(store.removeSession(for: id), "removing twice answers nil, not a crash")
    }

    func testReloadFiltersByKind() async {
        let store = IDEDiagramSessionStore()
        let classes = makeSession(.classes(.project))
        let modules = makeSession(.gradleModules)
        for session in [classes, modules] {
            session.load = { _, _ in IDEDiagramLoad(document: .empty(title: "stub")) }
        }
        store.register(classes, for: UUID())
        store.register(modules, for: UUID())

        store.reload(classes: true)
        await waitForCondition("the class diagram reloads", timeout: 2) { classes.loadedAt != nil }
        XCTAssertNil(modules.loadedAt, "a module diagram ignores the class-diagram refresh")

        store.reload(classes: false)
        await waitForCondition("the module diagram reloads", timeout: 2) { modules.loadedAt != nil }
    }
}
