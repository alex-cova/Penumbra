import AppKit
import XCTest
import Penumbra
@testable import EditorIntelligence

/// The reusable composition layers added for framework integrations (Spring first, JPA and others later):
/// merged gutter markers, additive usages across services, and cross-file code actions through the host preview.
final class ProviderCompositionTests: XCTestCase {
    // MARK: Fakes

    private struct Markers: LineMarkerProviding {
        let tag: String
        let markers: [LineMarker]?
        var siblings: [Location] = []
        func lineMarkers(source: String, fileURL: URL?, kinds: Set<LineMarkerKind>) async -> [LineMarker]? { markers }
        func siblingTargets(of marker: LineMarker, source: String, fileURL: URL?, documentID: DocumentID) async -> [Location] {
            siblings + [Location(documentID: documentID, range: Self.zero, displayName: "\(tag):\(marker.payload as? String ?? "-")")]
        }
        static let zero = TextRange(start: TextPosition(line: 0, column: 0, utf16Offset: 0), end: TextPosition(line: 0, column: 0, utf16Offset: 0))
    }

    private func marker(_ kind: LineMarkerKind, line: Int, anchor: Int = 0, payload: String? = nil) -> LineMarker {
        LineMarker(kind: kind, line: line, anchorUTF16Offset: anchor, tooltip: "", payload: payload)
    }

    private struct Service: LanguageService {
        let name: String
        let languageIdentifiers: Set<String> = ["x"]
        let providers: LanguageProviders
        var policy: LanguagePolicy { .none }
        var tier: LanguageServiceTier = .semantic
        var lineMarkerDescriptorList: [LineMarkerDescriptor] = []
        var lineMarkerDescriptors: [LineMarkerDescriptor] { lineMarkerDescriptorList }
    }

    private struct Nav: NavigationProvider {
        let name: String
        let byKind: [NavigationKind: [String]]
        func provide(context: NavigationContext) async -> NavigationResult? {
            guard let names = byKind[context.kind], !names.isEmpty else { return nil }
            let locs = names.map { Location(documentID: context.document.id, url: URL(fileURLWithPath: "/\($0)"), range: Markers.zero, displayName: $0) }
            return locs.count == 1 ? .single(locs[0]) : .multiple(locs)
        }
        func isPrimary(for context: NavigationContext) -> Bool { true }
    }

    private func document() -> Document {
        let p = TextPosition(line: 0, column: 0, utf16Offset: 0)
        return Document(url: URL(fileURLWithPath: "/d.x"), displayName: "d", contentSnapshot: TextSnapshot(version: 0, text: ""),
                        selection: Selection(range: TextRange(start: p, end: p)), cursor: Cursor(position: p),
                        viewport: Viewport(x: 0, y: 0, width: 1, height: 1), languageIdentifier: "x")
    }

    // MARK: Line markers

    func testCompositeMergesOrdersAndDedupes() async throws {
        let a = Markers(tag: "a", markers: [marker(.implemented, line: 5), marker(.overriding, line: 1)])
        let b = Markers(tag: "b", markers: [marker(.implemented, line: 5), marker(.implementing, line: 3)])
        let result = await CompositeLineMarkerProvider([a, b]).lineMarkers(source: "", fileURL: nil, kinds: [])
        let merged = try XCTUnwrap(result)
        XCTAssertEqual(merged.map(\.line), [1, 3, 5], "ordered by line; the repeated (kind, line, anchor) marker appears once")
    }

    func testCompositeAnswersNilOnlyWhenEveryProviderDid() async {
        let some = Markers(tag: "a", markers: [marker(.implemented, line: 2)])
        let none = Markers(tag: "b", markers: nil)
        let partial = await CompositeLineMarkerProvider([none, some]).lineMarkers(source: "", fileURL: nil, kinds: [])
        XCTAssertEqual(partial?.count, 1, "one provider failing does not blank the gutter")
        let allNil = await CompositeLineMarkerProvider([none, none]).lineMarkers(source: "", fileURL: nil, kinds: [])
        XCTAssertNil(allNil)
    }

    func testSiblingTargetsReachTheProviderThatProducedTheMarker() async throws {
        let a = Markers(tag: "a", markers: [marker(.implemented, line: 1, payload: "pa")])
        let b = Markers(tag: "b", markers: [marker(.overridden, line: 2, payload: "pb")])
        let composite = CompositeLineMarkerProvider([a, b])
        let result = await composite.lineMarkers(source: "", fileURL: nil, kinds: [])
        let merged = try XCTUnwrap(result)
        let id = DocumentID()
        let fromB = await composite.siblingTargets(of: merged[1], source: "", fileURL: nil, documentID: id)
        XCTAssertEqual(fromB.map(\.displayName), ["b:pb"], "payload unwrapped and routed to provider b")
        let fromA = await composite.siblingTargets(of: merged[0], source: "", fileURL: nil, documentID: id)
        XCTAssertEqual(fromA.map(\.displayName), ["a:pa"])
    }

    func testRegistryReturnsTheProviderItselfForASingleOwnerAndACompositeForForSeveral() {
        let one = Markers(tag: "a", markers: [])
        let single = LanguageServiceRegistry(services: [Service(name: "a", providers: LanguageProviders(lineMarkers: one))])
        XCTAssertTrue(single.lineMarkers(for: "x") is Markers, "a language with one owner is unchanged")
        let both = LanguageServiceRegistry(services: [
            Service(name: "a", providers: LanguageProviders(lineMarkers: one)),
            Service(name: "b", providers: LanguageProviders(lineMarkers: Markers(tag: "b", markers: []))),
            Service(name: "c", providers: LanguageProviders()),
        ])
        XCTAssertEqual((both.lineMarkers(for: "x") as? CompositeLineMarkerProvider)?.providers.count, 2)
        XCTAssertNil(LanguageServiceRegistry(services: [Service(name: "c", providers: LanguageProviders())]).lineMarkers(for: "x"))
    }

    // MARK: Usages are additive, definitions are not

    func testReferencesMergeAcrossServicesOfOneTierButDefinitionStaysFirstWins() async throws {
        let lang = Service(name: "lang", providers: LanguageProviders(navigation: [Nav(name: "n", byKind: [.references: ["U1", "U2"], .definition: ["D1"]])]))
        let framework = Service(name: "fw", providers: LanguageProviders(navigation: [Nav(name: "n", byKind: [.references: ["U2", "F1"], .definition: ["D2"]])]))
        let registry = LanguageServiceRegistry(services: [framework, lang])
        let provider = try XCTUnwrap(registry.navigationProviders.first)
        let doc = document()
        func context(_ kind: NavigationKind) -> NavigationContext { NavigationContext(document: doc, cursor: doc.cursor, selection: doc.selection, kind: kind) }
        let refs = await provider.provide(context: context(.references))
        XCTAssertEqual(refs?.locations.map(\.displayName), ["U2", "F1", "U1"], "framework first (registration order), duplicates removed")
        let def = await provider.provide(context: context(.definition))
        XCTAssertEqual(def?.locations.map(\.displayName), ["D2"], "definition: the first service that answers wins, as before")
    }

    func testReferencesWithOneAnsweringServiceAreUnchanged() async throws {
        let lang = Service(name: "lang", providers: LanguageProviders(navigation: [Nav(name: "n", byKind: [.references: ["U1", "U2"]])]))
        let silent = Service(name: "fw", providers: LanguageProviders(navigation: [Nav(name: "n", byKind: [:])]))
        let provider = try XCTUnwrap(LanguageServiceRegistry(services: [silent, lang]).navigationProviders.first)
        let doc = document()
        let refs = await provider.provide(context: NavigationContext(document: doc, cursor: doc.cursor, selection: doc.selection, kind: .references))
        XCTAssertEqual(refs?.locations.map(\.displayName), ["U1", "U2"])
    }

    // MARK: Cross-file code actions go through the host preview

    @MainActor
    func testWorkspacePlanCodeActionIsPresentedNotAppliedDirectly() async throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let textView = TextView(frame: window.contentView!.bounds)
        textView.theme = DefaultTheme()
        textView.text = "class A {}"
        window.contentView = textView
        let controller = EditorIntelligenceController(
            textView: textView, completionEngine: CompletionEngine(providers: [], debounceInterval: 0),
            hoverEngine: HoverEngine(providers: []), diagnosticEngine: DiagnosticEngine(providers: []))
        var presented: WorkspaceEditPlan?
        var applied = false
        controller.onPresentWorkspaceEditPlan = { plan, _ in presented = plan }
        controller.onWorkspaceEditApplied = { _ in applied = true }
        let other = URL(fileURLWithPath: "/other/B.java")
        let p = TextPosition(line: 0, column: 0, utf16Offset: 0)
        let entry = WorkspaceEditPlanEntry(url: other, range: TextRange(start: p, end: p), oldText: "", newText: "@Primary\n",
                                           lineText: "class B {}", description: "Add @Primary")
        let ownEdit = TextEdit(range: TextRange(start: p, end: p), replacement: "// ")
        controller.applyCodeAction(CodeAction(title: "Fix", edits: [ownEdit], workspacePlan: WorkspaceEditPlan(entries: [entry], title: "Fix")))
        XCTAssertEqual(presented?.entries.map(\.url), [other], "the cross-file part is shown in the preview")
        XCTAssertFalse(applied, "nothing is applied to other files before the user confirms")
        XCTAssertEqual(textView.text, "// class A {}", "the open document's own edit applies immediately")
    }

    func testCodeActionEqualityStillDistinguishesActions() {
        let a = CodeAction(title: "A", edits: [])
        XCTAssertEqual(a, a)
        XCTAssertNotEqual(a, CodeAction(title: "A", edits: []), "each action has its own identity")
    }

    // MARK: Extensible markers: descriptors, stacking, deduplication

    private let bean = LineMarkerDescriptor(id: "fw.bean", title: "Beans", group: "Framework", symbolName: "leaf", tint: .success, priority: 40)
    private let injection = LineMarkerDescriptor(id: "fw.inject", title: "Injection", group: "Framework", symbolName: "arrow.down", tint: .accent, priority: 30)

    func testStacksOrderByPriorityThenIdentityRegardlessOfInputOrder() {
        let markers = [
            LineMarker(descriptor: injection, line: 4, anchorUTF16Offset: 40, tooltip: "i"),
            LineMarker(kind: .recursiveCall, line: 4, anchorUTF16Offset: 41, tooltip: "r"),
            LineMarker(descriptor: bean, line: 4, anchorUTF16Offset: 30, tooltip: "b"),
            LineMarker(kind: .overriding, line: 4, anchorUTF16Offset: 20, tooltip: "o"),
            LineMarker(descriptor: bean, line: 9, anchorUTF16Offset: 90, tooltip: "b2"),
        ]
        let forward = LineMarkerPresentation.stacks(from: markers)
        let backward = LineMarkerPresentation.stacks(from: markers.reversed())
        XCTAssertEqual(forward.map(\.line), [4, 9])
        XCTAssertEqual(forward[0].markers.map(\.tooltip), ["o", "b", "i", "r"], "built-in overriding (60) > bean (40) > injection (30) > recursive (10)")
        XCTAssertEqual(forward[0].markers.map(\.tooltip), backward[0].markers.map(\.tooltip), "input order never changes the result")
        XCTAssertEqual(forward[0].visible.kind, .overriding)
        XCTAssertTrue(forward[0].isStacked)
        XCTAssertFalse(forward[1].isStacked)
    }

    func testOnlyExactRepeatsAreDropped() {
        let a = LineMarker(descriptor: bean, line: 2, anchorUTF16Offset: 10, tooltip: "first")
        let repeated = LineMarker(descriptor: bean, line: 2, anchorUTF16Offset: 10, tooltip: "second provider")
        let sameLineOtherAnchor = LineMarker(descriptor: bean, line: 2, anchorUTF16Offset: 12, tooltip: "other class on the line")
        let otherKind = LineMarker(descriptor: injection, line: 2, anchorUTF16Offset: 10, tooltip: "other kind")
        let stack = LineMarkerPresentation.stacks(from: [a, repeated, sameLineOtherAnchor, otherKind])[0]
        XCTAssertEqual(stack.markers.count, 3)
        XCTAssertEqual(Set(stack.markers.map(\.tooltip)), ["first", "other class on the line", "other kind"])
    }

    func testDescriptorsAreDeduplicatedAndSortedAcrossServices() {
        let svc = { (name: String, d: [LineMarkerDescriptor]) in Service(name: name, providers: LanguageProviders(), lineMarkerDescriptorList: d) }
        let registry = LanguageServiceRegistry(services: [
            svc("a", [injection, bean]), svc("b", [bean, LineMarkerDescriptor(id: "other.x", title: "X", group: "Another", symbolName: "x.circle")]),
        ])
        XCTAssertEqual(registry.lineMarkerDescriptors.map(\.id.rawValue), ["other.x", "fw.bean", "fw.inject"], "by group, then title; the repeated id appears once")
    }

    func testBuiltInKindsKeepTheirListAndExtendedIsNotOneOfThem() {
        XCTAssertEqual(LineMarkerKind.allCases.count, 6)
        XCTAssertFalse(LineMarkerKind.allCases.contains(.extended))
        XCTAssertEqual(LineMarkerKind(rawValue: "implemented"), .implemented, "saved preferences still decode")
        XCTAssertEqual(LineMarkerKind.overridden.stackPriority, LineMarkerKind.implemented.stackPriority)
    }
}
