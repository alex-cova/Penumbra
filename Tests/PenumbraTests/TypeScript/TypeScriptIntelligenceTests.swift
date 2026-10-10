import EditorIntelligence
import JavaIntelligence
import XCTest
@testable import Umbra

/// Syntactic TypeScript intelligence: the tree-sitter document layer, the project index, and the
/// providers Umbra registers for `typescript`.
final class TypeScriptIntelligenceTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots {
            try? FileManager.default.removeItem(at: root)
        }
        roots.removeAll()
        super.tearDown()
    }

    /// A few hundred nested nodes used to overflow the cooperative thread stack inside `walk`.
    func testDeepNestingStillIndexesTheLeaf() {
        let depth = 250
        let wrapped = "declare type T = " + String(repeating: "(", count: depth) + "Foo" + String(repeating: ")", count: depth)
        let parsed = TypeScriptAnalysis.parse(wrapped)
        XCTAssertEqual(parsed?.model.declarations.first?.name, "T", parsed?.tree.rootNode.sExpression ?? "no tree")
        XCTAssertTrue(parsed?.model.uses.contains { $0.name == "Foo" && $0.inTypePosition } == true)

        let names = (0..<depth).map { "n\($0)" }
        let chained = TypeScriptAnalysis.parse("const value = " + names.joined(separator: "."))
        XCTAssertEqual(chained?.model.declarations.first?.name, "value")
        let used = Set(chained?.model.uses.map(\.name) ?? [])
        XCTAssertTrue(used.contains("n0"))
        XCTAssertTrue(used.contains("n\(depth - 1)"))
    }

    func testParserSeesAnInterfaceAndTheJavaParserStaysJava() {
        let parsed = TypeScriptAnalysis.parse("interface Foo { bar: string }")
        XCTAssertEqual(parsed?.model.declarations.first?.kind, .interface, parsed?.tree.rootNode.sExpression ?? "no tree")
        XCTAssertEqual(parsed?.model.declarations.first?.name, "Foo")
        XCTAssertEqual(parsed?.model.declarations.first?.members.first?.name, "bar")

        let java = JavaSyntaxParser().parse("class A {}")
        XCTAssertEqual(java?.rootNode.namedChildren.first?.type, "class_declaration")
    }

    func testRelativeImportResolvesAndNodeModulesIsAbsentAndTheOpenBufferWins() async throws {
        let root = try makeProject([
            "src/a.ts": "export function widget() {}\n",
            "src/b.ts": "import { widget } from \"./a\"\n",
            "node_modules/pkg/index.ts": "export const hidden = 1\n",
            "src/disk.ts": "export const disk = 1\n"
        ])
        let index = TypeScriptIndex()
        await index.setRoot(root)

        let a = root.appendingPathComponent("src/a.ts")
        let b = root.appendingPathComponent("src/b.ts")
        let hidden = root.appendingPathComponent("node_modules/pkg/index.ts")
        let disk = root.appendingPathComponent("src/disk.ts")
        let hasA = await index.contains(a)
        let hasHidden = await index.contains(hidden)
        XCTAssertTrue(hasA)
        XCTAssertFalse(hasHidden)
        let resolved = await index.resolve(specifier: "./a", from: b)
        XCTAssertEqual(resolved?.standardizedFileURL, a.standardizedFileURL)
        let exported = await index.resolvedExport(named: "widget", in: a)
        XCTAssertEqual(exported?.declaration.name, "widget")

        let live = disk.standardizedFileURL
        await index.setOpenBufferLookup { url in
            url.standardizedFileURL == live ? "export const live = 1\n" : nil
        }
        let model = await index.model(for: disk)
        XCTAssertEqual(model?.topLevelDeclaration(named: "live")?.name, "live")
        XCTAssertNil(model?.topLevelDeclaration(named: "disk"))
    }

    func testCompletionOffersLocalsImportsAndAnnotatedMembersAndNothingForJava() async throws {
        let root = try makeProject([
            "a.ts": "export function widget() {}\n"
        ])
        let services = makeServices()
        await services.index.setRoot(root)
        let b = root.appendingPathComponent("b.ts")
        let imported = "import { widget } from \"./a\"\nw/*|*/"
        let importedDoc = try document(marked: imported, url: b)
        let importedItems = await services.completion.provide(context: completion(importedDoc, prefix: "w"))
        XCTAssertTrue(importedItems.contains { $0.label == "widget" }, labels(importedItems))

        let local = "function f(name: string) { na/*|*/ }"
        let localDoc = try document(marked: local, url: nil)
        let localItems = await services.completion.provide(context: completion(localDoc, prefix: "na"))
        XCTAssertTrue(localItems.contains { $0.label == "name" }, labels(localItems))

        let member = "interface Foo { bar: string }\nconst x: Foo\nx./*|*/"
        let memberSource = try stripped(member)
        let memberDoc = try document(marked: member, url: nil)
        let memberItems = await services.completion.provide(context: completion(memberDoc, prefix: ""))
        let tree = TypeScriptAnalysis.parse(memberSource.source)?.tree.rootNode.sExpression ?? ""
        XCTAssertTrue(memberItems.contains { $0.label == "bar" }, "labels=\(labels(memberItems)) tree=\(tree)")

        let java = document(language: "java", text: "class A {}", caret: 0, url: nil)
        let javaItems = await services.completion.provide(context: completion(java, prefix: ""))
        XCTAssertTrue(javaItems.isEmpty)
        XCTAssertFalse(services.completion.isPrimary(for: completion(java, prefix: "")))
    }

    func testAutoImportInsertsARelativeImport() async throws {
        let root = try makeProject([
            "a.ts": "export function widget() {}\n",
            "b.ts": "wid\n"
        ])
        let services = makeServices()
        await services.index.setRoot(root)
        let b = root.appendingPathComponent("b.ts")
        let doc = try document(marked: "wid/*|*/\n", url: b)
        let items = await services.completion.provide(context: completion(doc, prefix: "wid"))
        let widget = items.first { $0.label == "widget" }
        XCTAssertNotNil(widget, labels(items))
        let edits = widget?.additionalEdits.map(\.replacement).joined() ?? ""
        XCTAssertTrue(edits.contains("import"), edits)
        XCTAssertTrue(edits.contains("widget"), edits)
    }

    func testDefinitionOfAnImportedName() async throws {
        let root = try makeProject([
            "a.ts": "export function widget() {}\n",
            "b.ts": "import { widget } from \"./a\"\nwidget\n"
        ])
        let services = makeServices()
        await services.index.setRoot(root)
        let b = root.appendingPathComponent("b.ts")
        let doc = try document(marked: "import { widget } from \"./a\"\nwidget/*|*/\n", url: b)
        let result = await services.navigation.provide(context: navigation(doc, kind: .definition))
        guard case .single(let location) = result else {
            XCTFail("expected one definition, got \(String(describing: result))")
            return
        }
        XCTAssertEqual(location.url?.standardizedFileURL, root.appendingPathComponent("a.ts").standardizedFileURL)
        XCTAssertEqual(location.displayName, "widget")
    }

    func testUsagesOfAnExportIncludeTheImportAndSkipAShadowingLocal() async throws {
        let bSource = """
        import { value } from "./a"
        const value = 2
        value
        """
        let root = try makeProject([
            "a.ts": "export const value = 1\n",
            "b.ts": bSource
        ])
        let services = makeServices()
        await services.index.setRoot(root)
        let a = root.appendingPathComponent("a.ts")
        let doc = try document(marked: "export const value/*|*/ = 1\n", url: a)
        let result = await services.navigation.provide(context: navigation(doc, kind: .references))
        guard case .multiple(let locations) = result else {
            XCTFail("expected usages, got \(String(describing: result))")
            return
        }
        let b = root.appendingPathComponent("b.ts").standardizedFileURL
        let inB = locations.filter { $0.url?.standardizedFileURL == b }
        XCTAssertFalse(inB.isEmpty)
        let occurrences = ranges(of: "value", in: bSource)
        XCTAssertEqual(occurrences.count, 3)
        let offsets = Set(inB.map { $0.range.start.utf16Offset })
        XCTAssertTrue(offsets.contains(occurrences[0].location), "import site missing: \(offsets)")
        XCTAssertFalse(offsets.contains(occurrences[2].location), "shadowed use included: \(offsets)")
    }

    func testRenameReplacesBothUsesOfALocal() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rename-\(UUID().uuidString).ts")
        let services = makeServices()
        let doc = try document(marked: "const value/*|*/ = 1\nvalue\n", url: url)
        let context = navigation(doc, kind: .references)
        let target = await services.rename.prepareRename(context)
        XCTAssertEqual(target?.currentName, "value")
        let plan = try await services.rename.rename(context, to: "other")
        XCTAssertNil(plan.blockingError)
        XCTAssertEqual(plan.entries.count, 2)
        XCTAssertTrue(plan.entries.allSatisfy { $0.oldText == "value" && $0.newText == "other" })
    }

    func testSyntaxErrorOnABrokenFunctionAndNoneOnAConst() async throws {
        let services = makeServices()
        let broken = try document(marked: "function ( {/*|*/", url: nil)
        let errors = await services.diagnostics.diagnostics(for: broken)
        let tree = TypeScriptAnalysis.parse("function ( {")?.tree.rootNode.sExpression ?? ""
        XCTAssertFalse(errors.isEmpty, tree)
        XCTAssertEqual(errors.first?.message, "Syntax error")
        XCTAssertEqual(errors.first?.code, "syntax")

        let clean = document(language: "typescript", text: "const x = 1", caret: 0, url: nil)
        let none = await services.diagnostics.diagnostics(for: clean)
        let cleanTree = TypeScriptAnalysis.parse("const x = 1")?.tree.rootNode.sExpression ?? ""
        XCTAssertTrue(none.isEmpty, "\(none.map(\.message)) \(cleanTree)")
    }

    func testStructureListsTheMethodAndTheClassNameIsATypeToken() async {
        let services = makeServices()
        let source = "class Foo { bar() {} }"
        let outline = await services.structure.structure(forSource: source, atUTF16Offset: 0)
        XCTAssertEqual(outline?.title, "Foo")
        XCTAssertEqual(outline?.kind, .type)
        XCTAssertTrue(outline?.children.contains { $0.title == "bar" && $0.kind == .method } == true, "\(String(describing: outline))")

        let tokens = await services.tokens.semanticHighlights(forSource: source)
        let foo = (source as NSString).range(of: "Foo")
        XCTAssertTrue(tokens?.contains { token in
            token.highlightName == "type.class" && token.range.lowerBound == foo.location
        } == true, "\(String(describing: tokens))")
    }

    func testProvidersReturnNothingForAJavaDocument() async {
        let services = makeServices()
        let doc = document(language: "java", text: "class A { int x; }", caret: 6, url: nil)
        let javaItems = await services.completion.provide(context: completion(doc, prefix: ""))
        let definition = await services.navigation.provide(context: navigation(doc, kind: .definition))
        let references = await services.navigation.provide(context: navigation(doc, kind: .references))
        let implementation = await services.navigation.provide(context: navigation(doc, kind: .implementation))
        let diagnostics = await services.diagnostics.diagnostics(for: doc)
        let rename = await services.rename.prepareRename(navigation(doc, kind: .definition))
        let breadcrumbs = await services.structure.breadcrumbs(for: doc)
        XCTAssertTrue(javaItems.isEmpty)
        XCTAssertNil(definition)
        XCTAssertNil(references)
        XCTAssertNil(implementation)
        XCTAssertTrue(diagnostics.isEmpty)
        XCTAssertNil(rename)
        XCTAssertNil(breadcrumbs)
        XCTAssertTrue(services.completion.isPrimary(for: completion(
            document(language: "typescript", text: "const x = 1", caret: 0, url: nil), prefix: ""
        )))
    }

    // MARK: - Fixtures

    private struct Services {
        var index: TypeScriptIndex
        var completion: TypeScriptCompletionProvider
        var navigation: TypeScriptNavigationProvider
        var diagnostics: TypeScriptDiagnosticProvider
        var rename: TypeScriptRenameProvider
        var structure: TypeScriptStructureProvider
        var tokens: TypeScriptSemanticTokenProvider
    }

    private func makeServices() -> Services {
        let cache = TypeScriptAnalysis.makeCache()
        let index = TypeScriptIndex()
        return Services(
            index: index,
            completion: TypeScriptCompletionProvider(cache: cache, index: index),
            navigation: TypeScriptNavigationProvider(cache: cache, index: index),
            diagnostics: TypeScriptDiagnosticProvider(cache: cache),
            rename: TypeScriptRenameProvider(cache: cache, index: index),
            structure: TypeScriptStructureProvider(),
            tokens: TypeScriptSemanticTokenProvider()
        )
    }

    private func makeProject(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ts-intel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        roots.append(root)
        return root
    }

    private func stripped(_ marked: String) throws -> (source: String, caret: Int) {
        let ns = marked as NSString
        let range = ns.range(of: "/*|*/")
        if range.location == NSNotFound {
            throw NSError(domain: "TypeScriptIntelligenceTests", code: 1)
        }
        return (ns.replacingCharacters(in: range, with: ""), range.location)
    }

    private func document(marked: String, url: URL?) throws -> Document {
        let parts = try stripped(marked)
        return document(language: "typescript", text: parts.source, caret: parts.caret, url: url)
    }

    private func document(language: String, text: String, caret: Int, url: URL?) -> Document {
        let position = TextPosition(line: 0, column: caret, utf16Offset: caret)
        return Document(
            url: url,
            displayName: url?.lastPathComponent ?? "Untitled",
            contentSnapshot: TextSnapshot(version: 1, text: text),
            selection: Selection(range: TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 800, height: 600),
            languageIdentifier: language
        )
    }

    private func completion(_ document: Document, prefix: String) -> CompletionContext {
        let end = document.cursor.position.utf16Offset
        let start = max(0, end - (prefix as NSString).length)
        let startPosition = TextPosition(line: 0, column: start, utf16Offset: start)
        return CompletionContext(
            document: document,
            cursor: document.cursor,
            trigger: .manual,
            prefix: prefix,
            range: TextRange(start: startPosition, end: document.cursor.position)
        )
    }

    private func navigation(_ document: Document, kind: NavigationKind) -> NavigationContext {
        NavigationContext(document: document, cursor: document.cursor, selection: document.selection, kind: kind)
    }

    private func labels(_ items: [CompletionItem]) -> String {
        items.map(\.label).joined(separator: ", ")
    }

    private func ranges(of needle: String, in text: String) -> [NSRange] {
        var found: [NSRange] = []
        let ns = text as NSString
        var search = NSRange(location: 0, length: ns.length)
        while true {
            let range = ns.range(of: needle, options: [], range: search)
            if range.location == NSNotFound { break }
            found.append(range)
            let next = range.location + range.length
            search = NSRange(location: next, length: ns.length - next)
        }
        return found
    }
}
