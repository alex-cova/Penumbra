import EditorIntelligence
import XCTest
@testable import Umbra

/// The Type/Method and Call hierarchy stores: lazy loading, the scope reaching the loader, and a
/// pinned copy that expands on its own.
@MainActor
final class IDEHierarchyStoreTests: XCTestCase {
    private func item(_ name: String) -> HierarchyItem {
        HierarchyItem(id: name, name: name, kind: .classType, origin: .project)
    }

    private func settle() async {
        for _ in 0 ..< 20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 30_000_000)
    }

    // MARK: - Type hierarchy

    func testScopeIsPassedToTheLoaderAndChangingItReloadsTheTree() async {
        let store = IDETypeHierarchyStore()
        var seen: [HierarchyScope] = []
        store.loader = { node, _, scope, _ in
            seen.append(scope)
            return scope == .tests ? [HierarchyItem(id: "T", name: "TestOnly", kind: .classType, origin: .project)] : [self.item("Prod")]
        }
        store.show(root: item("Base"), file: nil)
        store.setDirection(.subtypes)
        await settle()
        XCTAssertEqual(store.rows.map(\.node.name), ["Base", "Prod"])

        store.setScope(.tests)
        await settle()
        XCTAssertEqual(store.scope, .tests)
        XCTAssertEqual(store.rows.map(\.node.name), ["Base", "TestOnly"])
        XCTAssertEqual(seen.last, .tests)
    }

    func testSettingTheSameScopeDoesNotReload() async {
        let store = IDETypeHierarchyStore()
        var loads = 0
        store.loader = { _, _, _, _ in
            loads += 1
            return []
        }
        store.show(root: item("Base"), file: nil)
        await settle()
        let before = loads
        store.setScope(.all)
        await settle()
        XCTAssertEqual(loads, before)
    }

    func testAMethodHierarchyOpensDownwardAndRemembersItsLanguage() {
        let store = IDETypeHierarchyStore()
        store.show(root: item("Animal"), file: nil, kind: .method, languageIdentifier: "java")
        XCTAssertEqual(store.direction, .subtypes)
        XCTAssertEqual(store.kind, .method)
        XCTAssertEqual(store.languageIdentifier, "java")
    }

    func testAPinnedCopyKeepsItsTreeAndExpandsOnItsOwn() async {
        let store = IDETypeHierarchyStore()
        store.loader = { node, _, _, _ in
            node.name == "Root" ? [self.item("Child")] : [self.item("\(node.name)-below")]
        }
        store.show(root: item("Root"), file: nil, kind: .type, languageIdentifier: "java")
        await settle()
        XCTAssertEqual(store.rows.map(\.node.name), ["Root", "Child"])

        let pinned = store.copy()
        XCTAssertEqual(pinned.rows.map(\.node.name), ["Root", "Child"])
        XCTAssertEqual(pinned.languageIdentifier, "java")

        // The live view moves on; the copy does not.
        store.show(root: item("Other"), file: nil)
        await settle()
        XCTAssertEqual(pinned.rows.map(\.node.name), ["Root", "Child"])

        // And the copy expands with the loader it was pinned with.
        let child = pinned.rows[1].node
        pinned.toggle(child)
        await settle()
        XCTAssertEqual(pinned.rows.map(\.node.name), ["Root", "Child", "Child-below"])
        XCTAssertEqual(store.rows.map(\.node.name).first, "Other")
    }

    // MARK: - Call hierarchy

    func testCallStoreScopeReloadsCallersAndPinsKeepTheirTree() async {
        let store = IDECallHierarchyStore()
        var scopes: [HierarchyScope] = []
        store.loader = { _, _, scope, _ in
            scopes.append(scope)
            return [self.item(scope == .production ? "prodCaller" : "anyCaller")]
        }
        store.show(root: item("target"), file: nil, languageIdentifier: "java")
        store.toggle(store.rows[0].node)
        await settle()
        XCTAssertEqual(store.rows.map(\.node.name), ["target", "anyCaller"])

        let pinned = store.copy()
        store.setScope(.production)
        await settle()
        XCTAssertEqual(store.rows.map(\.node.name), ["target", "prodCaller"])
        XCTAssertEqual(pinned.rows.map(\.node.name), ["target", "anyCaller"], "a pin keeps what it showed")
        XCTAssertEqual(pinned.languageIdentifier, "java")
        XCTAssertEqual(scopes.last, .production)
    }
}
