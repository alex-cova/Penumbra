import EditorIntelligence
import JavaIntelligence
import XCTest
@testable import Umbra

/// The Swift providers Umbra registers, against small projects on disk with `/*|*/` as the caret.
final class SwiftIntelligenceTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    // MARK: Completion

    func testMemberCompletionIncludesExtensionMembersFromAnotherFile() async throws {
        let fixture = try await makeFixture([
            "Point.swift": "struct Point {\n    var x: Int\n    static let zero = Point(x: 0)\n    func moved() -> Point { self }\n}\n",
            "Point+Math.swift": "extension Point {\n    func length() -> Double { 0 }\n}\n",
            "main.swift": "let p = Point(x: 1)\np./*|*/\n"
        ], caretIn: "main.swift")
        let items = await fixture.services.completion.provide(context: fixture.completion(prefix: ""))
        let names = Set(items.map(\.label))
        XCTAssertTrue(names.isSuperset(of: ["x", "moved", "length"]), labels(items))
        XCTAssertFalse(names.contains("zero"), "a static member is not on an instance")
        XCTAssertFalse(names.contains("if"), "no keywords after a dot")
    }

    func testStaticAndEnumCaseCompletionOnATypeAndOnAnExpectedType() async throws {
        let files = [
            "Color.swift": "enum Color {\n    case red, green\n    static let brand = Color.red\n    var name: String { \"\" }\n}\n",
            "Paint.swift": "func paint(_ color: Color) {}\n"
        ]
        let onType = try await makeFixture(
            files.merging(["main.swift": "let c = Color./*|*/\n"]) { $1 }, caretIn: "main.swift"
        )
        let typeItems = Set(await onType.services.completion.provide(context: onType.completion(prefix: "")).map(\.label))
        XCTAssertTrue(typeItems.isSuperset(of: ["red", "green", "brand"]), "\(typeItems)")
        XCTAssertFalse(typeItems.contains("name"))

        let annotated = try await makeFixture(
            files.merging(["main.swift": "let c: Color = ./*|*/\n"]) { $1 }, caretIn: "main.swift"
        )
        let annotatedItems = Set(await annotated.services.completion.provide(context: annotated.completion(prefix: "")).map(\.label))
        XCTAssertTrue(annotatedItems.isSuperset(of: ["red", "green"]), "\(annotatedItems)")

        let argument = try await makeFixture(
            files.merging(["main.swift": "paint(./*|*/)\n"]) { $1 }, caretIn: "main.swift"
        )
        let argumentItems = Set(await argument.services.completion.provide(context: argument.completion(prefix: "")).map(\.label))
        XCTAssertTrue(argumentItems.isSuperset(of: ["red", "green"]), "\(argumentItems)")
    }

    func testScopeCompletionOffersLocalsParametersAndNoJavaScriptSnippets() async throws {
        let fixture = try await makeFixture([
            "main.swift": "struct Box { var width = 1 }\nfunc area(of box: Box, scale: Int) -> Int {\n    let result = 0\n    /*|*/\n}\n"
        ], caretIn: "main.swift")
        let items = await fixture.services.completion.provide(context: fixture.completion(prefix: ""))
        let names = Set(items.map(\.label))
        XCTAssertTrue(names.isSuperset(of: ["box", "scale", "result", "Box", "func", "guard let", "return"]), labels(items))
        let snippet = items.first { $0.label == "func" && $0.kind == .snippet }
        XCTAssertFalse(snippet?.insertText.contains("function") ?? false, "Swift is not JavaScript")
        let box = try XCTUnwrap(items.first { $0.label == "box" })
        XCTAssertEqual(box.detail, "Box")
    }

    func testStandardLibraryMembersOfAWrittenType() async throws {
        let fixture = try await makeFixture([
            "main.swift": "func f(name: String, items: [Int]) {\n    name./*|*/\n}\n"
        ], caretIn: "main.swift")
        let items = await fixture.services.completion.provide(context: fixture.completion(prefix: ""))
        XCTAssertTrue(Set(items.map(\.label)).isSuperset(of: ["count", "hasPrefix", "uppercased"]), labels(items))
    }

    func testGuardLetBindingIsAMemberReceiverAfterTheGuard() async throws {
        let fixture = try await makeFixture([
            "Point.swift": "struct Point { var x: Int }\n",
            "main.swift": "func f(maybe: Point?) {\n    guard let point = maybe else { return }\n    point./*|*/\n}\n"
        ], caretIn: "main.swift")
        let items = await fixture.services.completion.provide(context: fixture.completion(prefix: ""))
        XCTAssertTrue(items.contains { $0.label == "x" }, labels(items))
    }

    func testCompletionAddsAnImportForAnotherModule() async throws {
        let fixture = try await makeFixture([
            "Lib/Thing.swift": "public struct LibThing {}\n",
            "App/main.swift": "import Foundation\nlet value = LibTh/*|*/\n"
        ], caretIn: "App/main.swift", modules: ["Lib": "Lib", "App": "App"])
        let items = await fixture.services.completion.provide(context: fixture.completion(prefix: "LibTh"))
        let item = try XCTUnwrap(items.first { $0.label == "LibThing" }, labels(items))
        XCTAssertEqual(item.additionalEdits.first?.replacement, "\nimport Lib")
    }

    // MARK: Navigation

    func testDefinitionOfAMemberThroughATypedLocalAcrossFiles() async throws {
        let fixture = try await makeFixture([
            "Point.swift": "struct Point {\n    func moved() -> Point { self }\n}\n",
            "main.swift": "let p = Point()\nlet q = p.mov/*|*/ed()\n"
        ], caretIn: "main.swift")
        let result = await fixture.services.navigation.provide(context: fixture.navigation(.definition))
        guard case .single(let location)? = result else { return XCTFail("\(String(describing: result))") }
        XCTAssertEqual(location.url?.lastPathComponent, "Point.swift")
    }

    func testUsagesOfATypeAcrossFilesAndLocalShadowsAreSeparate() async throws {
        let fixture = try await makeFixture([
            "Widget.swift": "struct Wid/*|*/get {}\n",
            "a.swift": "let w = Widget()\nfunc f() { let Widget = 1; print(Widget) }\n",
            "b.swift": "func g(_ x: Widget) {}\n"
        ], caretIn: "Widget.swift")
        let result = await fixture.services.navigation.provide(context: fixture.navigation(.references))
        guard case .multiple(let locations)? = result else { return XCTFail("\(String(describing: result))") }
        let files = locations.map { $0.url?.lastPathComponent ?? "" }
        XCTAssertEqual(files.filter { $0 == "Widget.swift" }.count, 1)
        XCTAssertEqual(files.filter { $0 == "a.swift" }.count, 1, "the local `Widget` is another symbol: \(files)")
        XCTAssertEqual(files.filter { $0 == "b.swift" }.count, 1)
    }

    func testImplementationsOfAProtocolAndOfItsRequirement() async throws {
        let sources = [
            "Shape.swift": "protocol Shape {\n    func are/*|*/a() -> Double\n}\n",
            "Circle.swift": "struct Circle: Shape {\n    func area() -> Double { 1 }\n}\n",
            "Square.swift": "struct Square {}\nextension Square: Shape {\n    func area() -> Double { 2 }\n}\n"
        ]
        let fixture = try await makeFixture(sources, caretIn: "Shape.swift")
        let result = await fixture.services.navigation.provide(context: fixture.navigation(.implementation))
        guard case .multiple(let locations)? = result else { return XCTFail("\(String(describing: result))") }
        XCTAssertEqual(Set(locations.compactMap { $0.url?.lastPathComponent }), ["Circle.swift", "Square.swift"])

        let onType = try await makeFixture(
            sources.merging(["Shape.swift": "protocol Sha/*|*/pe {\n    func area() -> Double\n}\n"]) { $1 },
            caretIn: "Shape.swift"
        )
        let typeResult = await onType.services.navigation.provide(context: onType.navigation(.implementation))
        guard case .multiple(let types)? = typeResult else { return XCTFail("\(String(describing: typeResult))") }
        XCTAssertEqual(Set(types.compactMap { $0.url?.lastPathComponent }), ["Circle.swift", "Square.swift"])
    }

    func testSuperMethodOfAnOverrideAndOfAConformance() async throws {
        let fixture = try await makeFixture([
            "Base.swift": "class Base {\n    func run() {}\n}\n",
            "Child.swift": "class Child: Base {\n    override func ru/*|*/n() {}\n}\n"
        ], caretIn: "Child.swift")
        let result = await fixture.services.navigation.provide(context: fixture.navigation(.superMethod))
        guard case .single(let location)? = result else { return XCTFail("\(String(describing: result))") }
        XCTAssertEqual(location.url?.lastPathComponent, "Base.swift")
    }

    // MARK: Rename

    func testRenameAMemberAcrossFilesLeavesAnUnrelatedSameNamedMemberAlone() async throws {
        let fixture = try await makeFixture([
            "A.swift": "struct A {\n    func tur/*|*/n() {}\n}\nstruct B {\n    func turn() {}\n}\n",
            "use.swift": "func f(a: A, b: B) {\n    a.turn()\n    b.turn()\n}\n"
        ], caretIn: "A.swift")
        let plan = try await fixture.services.rename.rename(fixture.navigation(.references), to: "rotate")
        XCTAssertNil(plan.blockingError)
        let byFile = Dictionary(grouping: plan.entries, by: { $0.url.lastPathComponent })
        XCTAssertEqual(byFile["A.swift"]?.count, 1, "only A's declaration")
        XCTAssertEqual(byFile["use.swift"]?.count, 1, "only `a.turn()`")
        let target = await fixture.services.rename.prepareRename(fixture.navigation(.references))
        XCTAssertEqual(target?.currentName, "turn")
    }

    func testRenamingAProtocolRequirementRenamesItsImplementationsAndTheirCalls() async throws {
        let fixture = try await makeFixture([
            "Shape.swift": "protocol Shape {\n    func are/*|*/a() -> Double\n}\nclass Base {\n    func size() {}\n}\n",
            "Circle.swift": "struct Circle: Shape {\n    func area() -> Double { 1 }\n}\n",
            "Child.swift": "class Child: Base {\n    override func size() {}\n}\n",
            "use.swift": "func f(c: Circle, s: Shape) {\n    c.area()\n    s.area()\n}\n"
        ], caretIn: "Shape.swift")
        let plan = try await fixture.services.rename.rename(fixture.navigation(.references), to: "surface")
        XCTAssertNil(plan.blockingError)
        let byFile = Dictionary(grouping: plan.entries, by: { $0.url.lastPathComponent })
        XCTAssertEqual(byFile["Shape.swift"]?.count, 1)
        XCTAssertEqual(byFile["Circle.swift"]?.count, 1, "the implementation")
        XCTAssertEqual(byFile["use.swift"]?.count, 2, "both calls")
        XCTAssertNil(byFile["Child.swift"], "an unrelated override is left alone")

        let override = try await makeFixture([
            "Base.swift": "class Base {\n    func run() {}\n}\n",
            "Child.swift": "class Child: Base {\n    override func ru/*|*/n() {}\n}\n",
            "use.swift": "func f(b: Base) { b.run() }\n"
        ], caretIn: "Child.swift")
        let overridePlan = try await override.services.rename.rename(override.navigation(.references), to: "go")
        let files = Set(overridePlan.entries.map { $0.url.lastPathComponent })
        XCTAssertEqual(files, ["Base.swift", "Child.swift", "use.swift"], "renaming the override renames the base too")
    }

    func testRenameRejectsKeywordsAndInitializers() async throws {
        let fixture = try await makeFixture([
            "main.swift": "struct S {\n    var val/*|*/ue = 1\n}\n"
        ], caretIn: "main.swift")
        let plan = try await fixture.services.rename.rename(fixture.navigation(.references), to: "class")
        XCTAssertNotNil(plan.blockingError)
        let initializer = try await makeFixture(["main.swift": "struct S {\n    in/*|*/it() {}\n}\n"], caretIn: "main.swift")
        let target = await initializer.services.rename.prepareRename(initializer.navigation(.references))
        XCTAssertNil(target)
    }

    // MARK: Signature help, markers, hierarchies, Generate

    func testSignatureHelpListsOverloadsAndHighlightsTheArgumentBeingTyped() async throws {
        let fixture = try await makeFixture([
            "Box.swift": "struct Box {\n    func put(_ value: Int) {}\n    func put(value: Int, at index: Int = 0) {}\n}\n",
            "main.swift": "func f(box: Box) {\n    box.put(value: 1, at: /*|*/)\n}\n"
        ], caretIn: "main.swift")
        let help = SwiftSignatureHelpProvider(index: fixture.services.index)
        let model = await help.signatureHelp(for: fixture.document, at: fixture.document.cursor.position)
        let hints = try XCTUnwrap(model)
        XCTAssertEqual(hints.signatures.count, 2)
        XCTAssertEqual(hints.signatures[hints.activeSignature], "put(value: Int, at index: Int = …)")
        XCTAssertEqual(hints.activeParameter, 1)
    }

    func testLineMarkersForOverridesImplementationsAndSubtypes() async throws {
        let files = [
            "Shape.swift": "protocol Shape {\n    func area() -> Double\n}\nclass Base {\n    func run() {}\n}\n",
            "Circle.swift": "final class Circle: Base, Shape {\n    func area() -> Double { 1 }\n    override func run() { run() }\n}\n"
        ]
        let circle = try await makeFixture(files, caretIn: nil, open: "Circle.swift")
        let provider = SwiftLineMarkerProvider(index: circle.services.index)
        let below = await provider.lineMarkers(
            source: circle.document.text, fileURL: circle.document.url, kinds: Set(LineMarkerKind.allCases)
        ) ?? []
        func has(_ kind: LineMarkerKind, line: Int, in markers: [LineMarker]) -> Bool {
            markers.contains { $0.kind == kind && $0.line == line }
        }
        XCTAssertTrue(has(.implementing, line: 2, in: below), "\(below.map { "\($0.kind)@\($0.line)" })")
        XCTAssertTrue(has(.overriding, line: 3, in: below))
        XCTAssertTrue(has(.recursiveCall, line: 3, in: below))

        let shape = try await makeFixture(files, caretIn: nil, open: "Shape.swift")
        let above = await provider.lineMarkers(
            source: shape.document.text, fileURL: shape.document.url, kinds: Set(LineMarkerKind.allCases)
        ) ?? []
        XCTAssertTrue(has(.implemented, line: 1, in: above), "\(above.map { "\($0.kind)@\($0.line)" })")
        XCTAssertTrue(has(.implemented, line: 2, in: above))
        XCTAssertTrue(has(.overridden, line: 4, in: above))
        XCTAssertTrue(has(.overridden, line: 5, in: above))
        let onlyOverrides = await provider.lineMarkers(source: shape.document.text, fileURL: shape.document.url, kinds: [.overridden])
        XCTAssertTrue(onlyOverrides?.allSatisfy { $0.kind == .overridden } == true)
    }

    func testTypeHierarchyAndCallHierarchy() async throws {
        let fixture = try await makeFixture([
            "Shape.swift": "protocol Shape {}\nstruct Circle: Shape {}\nstruct Square {}\nextension Square: Shape {}\n",
            "calls.swift": "func target() {}\nfunc caller() { target() }\nfunc other() { caller() }\n"
        ], caretIn: nil, open: "Shape.swift")
        let types = SwiftTypeHierarchyProvider(index: fixture.services.index)
        let shapeSource = fixture.document.text
        let circleOffset = (shapeSource as NSString).range(of: "Circle").location + 1
        let rootItem = await types.rootItem(source: shapeSource, fileURL: fixture.document.url, utf16Offset: circleOffset)
        let root = try XCTUnwrap(rootItem)
        XCTAssertEqual(root.name, "Circle")
        let supers = await types.supertypes(of: root, file: fixture.document.url)
        XCTAssertEqual(supers.map(\.name), ["Shape"])
        let shape = try XCTUnwrap(supers.first)
        let subs = await types.subtypes(of: shape, file: fixture.document.url)
        XCTAssertEqual(subs.map(\.name), ["Circle", "Square"])
        let located = await types.location(of: shape, file: fixture.document.url)
        XCTAssertEqual(located?.url?.lastPathComponent, "Shape.swift")

        let callsURL = fixture.root.appendingPathComponent("calls.swift")
        let callsSource = try String(contentsOf: callsURL, encoding: .utf8)
        let calls = SwiftCallHierarchyProvider(index: fixture.services.index)
        let callerOffset = (callsSource as NSString).range(of: "caller() {").location + 1
        let callerRoot = await calls.rootItem(source: callsSource, fileURL: callsURL, utf16Offset: callerOffset)
        let callerItem = try XCTUnwrap(callerRoot)
        XCTAssertEqual(callerItem.name, "caller()")
        let callers = await calls.callers(of: callerItem, file: callsURL)
        XCTAssertEqual(callers.map(\.name), ["other()"])
        let callees = await calls.callees(of: callerItem, file: callsURL)
        XCTAssertEqual(callees.map(\.name), ["target()"])
    }

    func testGenerateAnInitializerDescriptionAndCodingKeys() async throws {
        let fixture = try await makeFixture([
            "main.swift": "struct Point {\n    var x: Int\n    let y: Double = 1\n    var z = 0\n    /*|*/\n}\n"
        ], caretIn: "main.swift")
        let provider = SwiftCodeGenerationProvider(index: fixture.services.index)
        let context = RefactoringContext(document: fixture.document, cursor: fixture.document.cursor, selection: fixture.document.selection)
        let generated = await provider.generationMenu(context)
        let menu = try XCTUnwrap(generated)
        XCTAssertEqual(menu.typeName, "Point")
        let initializer = try XCTUnwrap(menu.options.first { $0.kind == .constructor })
        // `let y = 1` cannot be set again, and `z`'s type comes from its initializer.
        XCTAssertEqual(initializer.fields.map(\.name), ["x", "z"])
        XCTAssertEqual(initializer.fields.map(\.typeText), ["Int", "Int"])

        let plan = await provider.generate(.constructor, fieldNames: ["x", "z"], context: context)
        XCTAssertNil(plan.blockingError)
        XCTAssertTrue(plan.entries[0].newText.contains("init(x: Int, z: Int) {"), plan.entries[0].newText)
        XCTAssertTrue(plan.entries[0].newText.contains("        self.x = x"))

        let description = await provider.generate(.toString, fieldNames: ["x", "y"], context: context)
        XCTAssertNil(description.blockingError)
        XCTAssertTrue(description.entries[0].newText.contains("var description: String {"))
        XCTAssertTrue(description.entries[0].newText.contains("\"Point(x: \\(x), y: \\(y))\""))
        XCTAssertEqual(description.entries.count, 2, "the conformance is added too")
        XCTAssertEqual(description.entries[1].newText, ": CustomStringConvertible")

        let keys = await provider.generate(SwiftCodeGenerationProvider.codingKeys, fieldNames: ["x", "y", "z"], context: context)
        XCTAssertTrue(keys.entries[0].newText.contains("case x, y, z"))
    }

    // MARK: Diagnostics, structure, colours, hover

    func testSyntaxProblemsAreWarningsAndValidCodeHasNone() async throws {
        let valid = document(text: "struct Ok {\n    func f() {}\n}\n", caret: 0, url: nil)
        let none = await makeServices().diagnostics.diagnostics(for: valid)
        XCTAssertTrue(none.isEmpty)
        let broken = document(text: "struct Broken {\n    func a( {\n}\n", caret: 0, url: nil)
        let found = await makeServices().diagnostics.diagnostics(for: broken)
        XCTAssertFalse(found.isEmpty)
        XCTAssertTrue(found.allSatisfy { $0.severity == .warning && $0.source == "Swift" })
    }

    func testStructureBreadcrumbsAndTokens() async throws {
        let source = "protocol P {}\nextension Point: P {\n    func go(by n: Int) {\n        let value = n\n    }\n}\nstruct Point {}\n"
        let services = makeServices()
        let all = await services.structure.allStructure(forSource: source)
        let titles = all?.map(\.title)
        XCTAssertEqual(titles, ["P", "extension Point: P", "Point"])
        XCTAssertEqual(all?[1].children.map(\.title), ["go(by:)"])
        XCTAssertEqual(all?[1].children.first?.kind, .method)

        let caret = (source as NSString).range(of: "let value").location
        let crumbs = await services.structure.breadcrumbs(
            for: document(text: source, caret: caret, url: URL(fileURLWithPath: "/tmp/p.swift"))
        )
        XCTAssertEqual(crumbs?.map(\.title), ["extension Point: P", "go(by:)"])

        let tokens = await services.tokens.semanticHighlights(forSource: source) ?? []
        let names = Set(tokens.map(\.highlightName))
        XCTAssertTrue(names.isSuperset(of: ["type.interface", "type.class", "function.declaration", "variable.parameter", "variable.local"]), "\(names)")
    }

    func testHoverShowsTheSignatureAndTheDocComment() async throws {
        let fixture = try await makeFixture([
            "Point.swift": "struct Point {\n    /// Moves the point.\n    func moved(by delta: Int) -> Point { self }\n}\n",
            "main.swift": "let p = Point()\nlet q = p.mov/*|*/ed(by: 1)\n"
        ], caretIn: "main.swift")
        let context = HoverContext(document: fixture.document, cursor: fixture.document.cursor, selection: fixture.document.selection)
        let hover = await fixture.services.hover.provide(context: context)
        XCTAssertTrue(hover?.contents.contains("func moved(by delta: Int) -> Point") == true, hover?.contents ?? "nil")
        XCTAssertTrue(hover?.contents.contains("Moves the point.") == true)
    }

    func testProvidersReturnNothingForAJavaDocument() async throws {
        let services = makeServices()
        let java = document(text: "class A { void f() { int x; x. } }", caret: 31, url: nil, language: "java")
        let context = CompletionContext(
            document: java, cursor: java.cursor, trigger: .manual, prefix: "",
            range: EditorIntelligence.TextRange(start: java.cursor.position, end: java.cursor.position)
        )
        XCTAssertFalse(services.completion.isPrimary(for: context))
        let items = await services.completion.provide(context: context)
        XCTAssertTrue(items.isEmpty)
        let diagnostics = await services.diagnostics.diagnostics(for: java)
        XCTAssertTrue(diagnostics.isEmpty)
        let breadcrumbs = await services.structure.breadcrumbs(for: java)
        XCTAssertNil(breadcrumbs)
        let navigation = NavigationContext(document: java, cursor: java.cursor, selection: java.selection, kind: .definition)
        let definition = await services.navigation.provide(context: navigation)
        XCTAssertNil(definition)
    }

    // MARK: Fixtures

    private struct Services {
        var index: SwiftIndex
        var completion: SwiftCompletionProvider
        var hover: SwiftHoverProvider
        var navigation: SwiftNavigationProvider
        var diagnostics: SwiftDiagnosticProvider
        var rename: SwiftRenameProvider
        var structure: SwiftStructureProvider
        var tokens: SwiftSemanticTokenProvider
    }

    private struct Fixture {
        var services: Services
        var document: Document
        var root: URL

        func completion(prefix: String) -> CompletionContext {
            let end = document.cursor.position.utf16Offset
            let start = max(0, end - (prefix as NSString).length)
            let startPosition = TextPosition(line: 0, column: start, utf16Offset: start)
            return CompletionContext(
                document: document, cursor: document.cursor, trigger: .manual, prefix: prefix,
                range: EditorIntelligence.TextRange(start: startPosition, end: document.cursor.position)
            )
        }

        func navigation(_ kind: NavigationKind) -> NavigationContext {
            NavigationContext(document: document, cursor: document.cursor, selection: document.selection, kind: kind)
        }
    }

    private func makeServices() -> Services {
        let index = SwiftIndex()
        return Services(
            index: index,
            completion: SwiftCompletionProvider(index: index),
            hover: SwiftHoverProvider(index: index),
            navigation: SwiftNavigationProvider(index: index),
            diagnostics: SwiftDiagnosticProvider(),
            rename: SwiftRenameProvider(index: index),
            structure: SwiftStructureProvider(),
            tokens: SwiftSemanticTokenProvider()
        )
    }

    /// Writes `files` (the one named by `caretIn` holds `/*|*/`), indexes the folder and returns the
    /// document the caret is in.
    private func makeFixture(
        _ files: [String: String], caretIn: String?, open: String? = nil, modules: [String: String] = [:]
    ) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-intel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        var caret = 0
        var caretText = ""
        for (path, text) in files {
            var written = text
            if path == open { caretText = text }
            if path == caretIn {
                let range = (text as NSString).range(of: "/*|*/")
                XCTAssertNotEqual(range.location, NSNotFound)
                caret = range.location
                written = (text as NSString).replacingCharacters(in: range, with: "")
                caretText = written
            }
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(written.utf8).write(to: url)
        }
        let services = makeServices()
        if !modules.isEmpty {
            let table = modules.map { (root.appendingPathComponent($0.key).standardizedFileURL.path, $0.value) }
            await services.index.setModuleResolver { url in
                let path = url.standardizedFileURL.path
                return table.first { path.hasPrefix($0.0) }?.1
            }
        }
        await services.index.setRoot(root)
        let url = root.appendingPathComponent(caretIn ?? open ?? "")
        return Fixture(services: services, document: document(text: caretText, caret: caret, url: url), root: root)
    }

    private func document(text: String, caret: Int, url: URL?, language: String = "swift") -> Document {
        let position = TextPosition(line: 0, column: caret, utf16Offset: caret)
        return Document(
            url: url,
            displayName: url?.lastPathComponent ?? "Untitled",
            contentSnapshot: TextSnapshot(version: 1, text: text),
            selection: Selection(range: EditorIntelligence.TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 800, height: 600),
            languageIdentifier: language
        )
    }

    private func labels(_ items: [CompletionItem]) -> String {
        items.map(\.label).sorted().joined(separator: ", ")
    }
}
