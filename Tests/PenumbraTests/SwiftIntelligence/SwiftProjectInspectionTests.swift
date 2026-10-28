import EditorIntelligence
import Foundation
import SwiftIntelligence
import XCTest

/// `unused-declaration`, the Swift inspection that needs the rest of the project: a name written nowhere else.
final class SwiftProjectInspectionTests: XCTestCase {
    private struct Lookup: SwiftModuleSurfaceLookup {
        var files: [String: Set<URL>] = [:]
        var surfaces: [String: SwiftModuleSurface] = [:]
        var modules: [URL: String] = [:]
        func filesMentioning(_ name: String) async -> Set<URL> { files[name] ?? [] }
        func moduleSurface(_ module: String) async -> SwiftModuleSurface? { surfaces[module] }
        func module(ofFile url: URL) async -> String? { modules[url.standardizedFileURL] }
    }

    private let file = URL(fileURLWithPath: "/proj/Sources/App/A.swift")
    private let other = URL(fileURLWithPath: "/proj/Sources/App/B.swift")

    private func unused(
        _ text: String, url: URL? = nil, isTest: Bool = false, lookup: Lookup = Lookup(), publicApiUsed: Bool = true
    ) async -> [String] {
        var options = SwiftInspectionOptions().only([.unusedDeclaration])
        options.treatsPublicApiAsUsed = publicApiUsed
        let analysis = await SwiftInspectionPipeline.analyze(
            text: text, options: options, url: url ?? file, isTest: isTest, lookup: lookup, cache: SwiftSyntaxParseCache(capacity: 1)
        )
        return analysis.findings.map { String(decoding: Array(text.utf8)[$0.bytes], as: UTF8.self) }
    }

    func testANameWrittenNowhereElseIsUnused() async {
        let text = "func orphan() {}\\nstruct Lonely {}\\nlet constant = 1\\nenum Mode { case a }\\nstruct Sphere {\\n    var value = 1\\n    func helper() {}\\n}\\n"
            .replacingOccurrences(of: "\\n", with: "\n")
        let names = await unused(text)
        XCTAssertEqual(names, ["orphan", "Lonely", "constant", "Mode", "Sphere", "value", "helper"])
    }

    func testANameWrittenInAnotherFileOrTwiceHereIsUsed() async {
        let text = "func shared() {}\nfunc local() {}\nfunc caller() { local() }\n"
        var lookup = Lookup()
        lookup.files["shared"] = [file, other]
        lookup.files["local"] = [file]
        lookup.files["caller"] = [file]
        let names = await unused(text, lookup: lookup)
        XCTAssertEqual(names, ["caller"], "`shared` is written in B.swift, `local` is called here")
        // Only this file mentioning it is the same as nobody else doing so.
        var onlyHere = Lookup()
        onlyHere.files["shared"] = [file]
        let again = await unused("func shared() {}\n", lookup: onlyHere)
        XCTAssertEqual(again, ["shared"])
    }

    func testWhatTheRuntimeOrAnotherModuleMayReachIsLeftAlone() async {
        for text in [
            "public func api() {}\n",
            "open class Base {}\n",
            "@objc func tapped() {}\n",
            "@main struct App {}\n",
            "@Observable final class Model { var value = 1 }\n",
            "class D: B {\n    override func f() {}\n}\n",
            "protocol P {\n    func requirement()\n}\n",
            "struct V: View {\n    var body: some View { Text(\"\") }\n}\n",
            "struct S {\n    private func hidden() {}\n}\n",
            "public func f() {\n    func local() {}\n    let inner = 1\n}\n",
            "enum E { case lonelyCase }\n",
            "struct S: Codable {\n    enum CodingKeys: String, CodingKey { case a }\n    var a = 1\n}\n",
            "@MainActor @propertyWrapper struct W { var wrappedValue = 0 }\n",
            "final class P: NSObject, XMLParserDelegate {\n    func parserDidEndDocument(_ parser: XMLParser) {}\n}\n",
            "extension T: NSPopoverDelegate {\n    func popoverWillClose(_ n: Notification) {}\n}\n",
            "struct ByteCount: Numeric {\n    typealias Magnitude = UInt\n}\n",
            "struct Box: Codable {\n    var width: Double\n    var height: Double\n}\n",
            "public struct Uniforms {\n    var scale: Float\n    var pad4: Float\n}\n",
            "public struct Pt {\n    var x: Double\n    var y: Double\n}\n",
        ] {
            let found = await unused(text)
            // Types and members the text itself names are fine to be reported; none of the leftovers may be.
            XCTAssertFalse(found.contains { ["api", "Base", "tapped", "App", "value", "f", "requirement", "body", "hidden", "local", "inner", "lonelyCase", "CodingKeys", "wrappedValue", "parserDidEndDocument", "popoverWillClose", "Magnitude", "width", "height", "pad4", "x", "y"].contains($0) }, "\(text) -> \(found)")
        }
        let publicNames = await unused("public func api() {}\n", publicApiUsed: false)
        XCTAssertEqual(publicNames, ["api"], "unless asked to look at public API too")
    }

    func testTestsAndMainAreNotInspected() async {
        let text = "func helperUsedByNobody() {}\n"
        let inTest = await unused(text, isTest: true)
        XCTAssertTrue(inTest.isEmpty)
        let inMain = await unused(text, url: URL(fileURLWithPath: "/proj/Sources/App/main.swift"))
        XCTAssertTrue(inMain.isEmpty)
    }

    func testTheCommentsThatSilenceARuleSilenceThisOneToo() async {
        let silenced = await unused("// umbra:disable unused-declaration\nfunc orphan() {}\n")
        XCTAssertTrue(silenced.isEmpty)
        let swiftLint = await unused("// swiftlint:disable:next unused_declaration\nfunc orphan() {}\n")
        XCTAssertTrue(swiftLint.isEmpty)
    }

    func testTheEditorsPassAndAPlainRunDoNotSearchTheProject() {
        let text = "func orphan() {}\n"
        let options = SwiftInspectionOptions()
        XCTAssertTrue(SwiftInspectionRule.unusedDeclaration.isProjectWide)
        XCTAssertTrue(SwiftInspectionPipeline.analyze(text: text, options: options, cache: SwiftSyntaxParseCache(capacity: 1)).findings.isEmpty)
        XCTAssertTrue(SwiftBatchInspector.located(in: text, options: .init(inspection: options)).isEmpty)
    }

    // MARK: - Against a real index

    func testARunOverAProjectReportsWhatNothingElseNames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("swift-unused-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("Sources/App/A.swift")
        let b = root.appendingPathComponent("Sources/App/B.swift")
        try "func used() {}\nfunc orphan() {}\nstruct Widget {}\n".write(to: a, atomically: true, encoding: .utf8)
        try "func caller() { used(); _ = Widget() }\nfunc run() { caller() }\n".write(to: b, atomically: true, encoding: .utf8)
        let index = SwiftIndex()
        await index.setRoot(root)

        let options = SwiftBatchInspector.Options(
            inspection: SwiftInspectionOptions(), onlyRules: [.unusedDeclaration], includeProjectRules: true, projectLookup: index
        )
        var found: [String: [String]] = [:]
        for await event in SwiftBatchInspector().run(files: [a, b], options: options, text: { try? String(contentsOf: $0, encoding: .utf8) }) {
            if case .file(let url, let findings) = event { found[url.lastPathComponent] = findings.map(\.inspection.message) }
        }
        XCTAssertEqual(found["A.swift"], ["'orphan' is never used in the project."])
        XCTAssertEqual(found["B.swift"], ["'run' is never used in the project."])

        // Without the switch the run does not search.
        var plain = options
        plain.includeProjectRules = false
        var none = 0
        for await event in SwiftBatchInspector().run(files: [a, b], options: plain, text: { try? String(contentsOf: $0, encoding: .utf8) }) {
            if case .file = event { none += 1 }
        }
        XCTAssertEqual(none, 0)
    }
}

/// `unused-import`: an import whose module the index knows and nothing in the file mentions —
/// not in code, comments or strings. Conservative by construction: its own module, `@testable`,
/// `@_exported`, scoped imports and unknown, re-exporting, operator-declaring or retroactively
/// conforming modules are never reported. Removal deletes the line, batched from Inspect Code.
final class SwiftUnusedImportTests: XCTestCase {
    private var root: URL!
    private var index: SwiftIndex!

    private func setUpProject(_ files: [String: String]) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "swift-unused-import-\(UUID().uuidString)", isDirectory: true)
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        index = SwiftIndex()
        await index.setModuleResolver { url in
            let components = url.pathComponents
            guard let i = components.lastIndex(of: "Sources"), i + 1 < components.count else { return nil }
            return components[i + 1]
        }
        await index.setRoot(root)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    private func main() -> URL {
        root.appendingPathComponent("Sources/App/Main.swift")
    }

    private func unusedImports(_ text: String, url: URL) async -> [SwiftInspection] {
        let analysis = await SwiftInspectionPipeline.analyze(
            text: text, options: SwiftInspectionOptions().only([.unusedImport]), url: url, lookup: index)
        return analysis.findings
    }

    private func kitApp(_ mainText: String) async throws -> (main: URL, findings: [SwiftInspection]) {
        try await setUpProject([
            "Sources/Kit/Kit.swift": "public struct Widget {}\npublic func make() -> Widget { Widget() }\n",
            "Sources/App/Main.swift": mainText,
        ])
        let url = main()
        return (url, await unusedImports(mainText, url: url))
    }

    func testUnusedImportIsReportedWithARemoveImportFix() async throws {
        let (url, findings) = try await kitApp("import Kit\n")
        XCTAssertEqual(findings.map(\.id), ["unused-import"])
        XCTAssertEqual(findings.map(\.message), ["import Kit is never used in this file."])
        let fix = try XCTUnwrap(findings.first?.fixes.first)
        XCTAssertEqual(fix.title, "Remove import")
        var bytes = Array("import Kit\n".utf8)
        for edit in fix.edits.sorted(by: { $0.bytes.lowerBound > $1.bytes.lowerBound }) {
            bytes.replaceSubrange(edit.bytes, with: Array(edit.replacement.utf8))
        }
        let fixed = String(decoding: bytes, as: UTF8.self)
        XCTAssertEqual(fixed, "")
        // The fixed file is clean.
        let refound = await unusedImports(fixed, url: url)
        XCTAssertTrue(refound.isEmpty)
    }

    func testUsedNameIsQuiet() async throws {
        let (_, findings) = try await kitApp("import Kit\nlet widget = Widget()\n")
        XCTAssertTrue(findings.isEmpty)
        let (_, usedFunc) = try await kitApp("import Kit\nlet widget = make()\n")
        XCTAssertTrue(usedFunc.isEmpty)
    }

    func testMentionInCommentOrStringIsQuiet() async throws {
        let (_, commented) = try await kitApp("import Kit\n// Widget shapes the layout\n")
        XCTAssertTrue(commented.isEmpty)
        let (_, stringed) = try await kitApp("import Kit\nlet name = \"make\"\n")
        XCTAssertTrue(stringed.isEmpty)
    }

    func testOwnModuleIsQuiet() async throws {
        try await setUpProject([
            "Sources/Kit/Kit.swift": "public struct Widget {}\n",
            "Sources/Kit/Other.swift": "import Kit\n",
        ])
        let url = root.appendingPathComponent("Sources/Kit/Other.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        let clean = await unusedImports(text, url: url)
        XCTAssertTrue(clean.isEmpty)
    }

    func testExportedImportIsQuiet() async throws {
        try await setUpProject([
            "Sources/Kit/Kit.swift": "public struct Widget {}\n",
            "Sources/Reexp/Reexp.swift": "@_exported import Kit\n",
            "Sources/App/Main.swift": "import Reexp\n",
        ])
        let url = main()
        let surface = await index.moduleSurface("Reexp")
        XCTAssertEqual(surface?.hasReexports, true)
        let clean = await unusedImports("import Reexp\n", url: url)
        XCTAssertTrue(clean.isEmpty)
    }

    func testExtensionMemberOnlyIsQuiet() async throws {
        try await setUpProject([
            "Sources/Ext/Ext.swift": "extension String {\n    public func shout() -> String { self }\n}\n",
            "Sources/App/Main.swift": "import Ext\nlet loud = \"hi\".shout()\n",
        ])
        let surface = await index.moduleSurface("Ext")
        XCTAssertTrue(surface?.names.contains("shout") ?? false)
        let url = main()
        let clean = await unusedImports("import Ext\nlet loud = \"hi\".shout()\n", url: url)
        XCTAssertTrue(clean.isEmpty)
    }

    func testOperatorModuleIsQuiet() async throws {
        try await setUpProject([
            "Sources/Ops/Ops.swift": "precedencegroup P { associativity: left }\ninfix operator <>: P\n",
            "Sources/OpsF/OpsF.swift": "public func <> (lhs: Int, rhs: Int) -> Int { lhs }\n",
            "Sources/App/Main.swift": "import Ops\nimport OpsF\n",
        ])
        let ops = await index.moduleSurface("Ops")
        XCTAssertEqual(ops?.declaresOperators, true)
        let opsF = await index.moduleSurface("OpsF")
        XCTAssertEqual(opsF?.declaresOperators, true)
        let url = main()
        let clean = await unusedImports("import Ops\nimport OpsF\n", url: url)
        XCTAssertTrue(clean.isEmpty)
    }

    func testRetroactiveConformanceIsQuiet() async throws {
        try await setUpProject([
            "Sources/Kit/Kit.swift": "public struct Widget {}\n",
            "Sources/Retro/Retro.swift": "extension Widget: CustomStringConvertible {\n    public var description: String { \"widget\" }\n}\n",
            "Sources/App/Main.swift": "import Retro\n",
        ])
        let retro = await index.moduleSurface("Retro")
        XCTAssertEqual(retro?.hasRetroactiveConformances, true)
        let url = main()
        let clean = await unusedImports("import Retro\n", url: url)
        XCTAssertTrue(clean.isEmpty)
    }

    func testUnknownScopedAndTestableImportsAreQuiet() async throws {
        try await setUpProject([
            "Sources/Kit/Kit.swift": "public struct Widget {}\n",
            "Sources/App/Main.swift": "import Foundation\nimport struct Kit.Widget\n@testable import Kit\n",
        ])
        let foundation = await index.moduleSurface("Foundation")
        XCTAssertNil(foundation)
        let url = main()
        let text = try String(contentsOf: url, encoding: .utf8)
        let clean = await unusedImports(text, url: url)
        XCTAssertTrue(clean.isEmpty)
    }

    func testBatchRunsUnusedImportWithoutTheProjectWideTick() async throws {
        try await setUpProject([
            "Sources/Kit/Kit.swift": "public struct Widget {}\n",
            "Sources/App/Main.swift": "import Kit\nfunc orphan() {}\n",
        ])
        let url = main()
        let text = try String(contentsOf: url, encoding: .utf8)
        let options = SwiftBatchInspector.Options(inspection: SwiftInspectionOptions(), projectLookup: index)
        let found = await SwiftBatchInspector().inspect(url: url, options: options, text: { _ in text })
        XCTAssertEqual(found.map(\.inspection.id), ["unused-import"])
    }

    func testBatchFixRemovesTheUnusedImportLine() async throws {
        try await setUpProject([
            "Sources/Kit/Kit.swift": "public struct Widget {}\n",
            "Sources/App/Main.swift": "import Kit\nlet number = 1\n",
        ])
        let url = main()
        let text = try String(contentsOf: url, encoding: .utf8)
        let result = await SwiftBatchFixer.fixAll(
            rules: [.unusedImport], in: text, url: url, lookup: index)
        XCTAssertEqual(result.fixedCount, 1)
        XCTAssertEqual(result.edits.count, 1)
        // The single fix deletes the first line.
        let map = SourceTextMap(text)
        var bytes = Array(text.utf8)
        for edit in result.edits.sorted(by: { $0.range.start.utf16Offset > $1.range.start.utf16Offset }) {
            let span = map.byteOffset(utf16: edit.range.start.utf16Offset) ..< map.byteOffset(utf16: edit.range.end.utf16Offset)
            bytes.replaceSubrange(span, with: Array(edit.replacement.utf8))
        }
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "let number = 1\n")
    }
}

/// The tree-sitter model flags `unused-import` and the surface builder read.
final class SwiftImportModelTests: XCTestCase {
    func testImportFlags() {
        let model = SwiftAnalysis.parseModel(
            "@_exported import Foo\nimport struct Bar.Baz\n@testable import Qux\nimport Plain\n")
        let byModule = Dictionary(uniqueKeysWithValues: (model?.imports ?? []).map { ($0.module, $0) })
        XCTAssertEqual(byModule["Foo"]?.isExported, true)
        XCTAssertEqual(byModule["Foo"]?.isTestable, false)
        XCTAssertEqual(byModule["Bar"]?.isScoped, true)
        XCTAssertEqual(byModule["Qux"]?.isTestable, true)
        XCTAssertEqual(byModule["Qux"]?.isExported, false)
        XCTAssertEqual(byModule["Plain"]?.isExported, false)
        XCTAssertEqual(byModule["Plain"]?.isScoped, false)
    }

    func testDeclaresOperators() {
        let plain = SwiftAnalysis.parseModel("public struct Widget {}\n")
        XCTAssertEqual(plain?.declaresOperators, false)
        let operators = SwiftAnalysis.parseModel(
            "precedencegroup P { associativity: left }\ninfix operator <>: P\npublic func <> (lhs: Int, rhs: Int) -> Int { lhs }\n")
        XCTAssertEqual(operators?.declaresOperators, true)
    }
}

/// The editor's index-backed pass: findings merge into the synchronous analysis by text hash,
/// the next edit drops them, and a stale entry still shows (shifted) instead of flickering.
final class SwiftIndexInspectionServiceTests: XCTestCase {
    private let file = URL(fileURLWithPath: "/proj/Sources/App/A.swift")

    private struct Lookup: SwiftModuleSurfaceLookup {
        var files: [String: Set<URL>] = [:]
        var surfaces: [String: SwiftModuleSurface] = [:]
        func filesMentioning(_ name: String) async -> Set<URL> { files[name] ?? [] }
        func moduleSurface(_ module: String) async -> SwiftModuleSurface? { surfaces[module] }
        func module(ofFile url: URL) async -> String? { nil }
    }

    private final class Pushed: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var values: [(URL, [Diagnostic])] = []
        func append(_ url: URL, _ diagnostics: [Diagnostic]) {
            lock.withLock { values.append((url, diagnostics)) }
        }
    }

    private final class OptionsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var current: SwiftInspectionOptions
        init(_ options: SwiftInspectionOptions) { current = options }
        var options: SwiftInspectionOptions {
            get { lock.withLock { current } }
            set { lock.withLock { current = newValue } }
        }
    }

    private func service(lookup: Lookup = Lookup(), pushed: Pushed = Pushed()) -> SwiftInspectionService {
        service(box: OptionsBox(SwiftInspectionOptions()), lookup: lookup, pushed: pushed)
    }

    private func service(box: OptionsBox, lookup: Lookup = Lookup(), pushed: Pushed = Pushed()) -> SwiftInspectionService {
        let service = SwiftInspectionService(options: { box.options })
        service.setIndexLookup(lookup)
        service.setIndexResultHandler { pushed.append($0, $1) }
        return service
    }

    private func document(_ text: String) -> Document {
        let origin = TextPosition(line: 0, column: 0, utf16Offset: 0)
        return Document(
            url: file, displayName: "A.swift",
            contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: EditorIntelligence.TextRange(start: origin, end: origin)),
            cursor: Cursor(position: origin), viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: "swift"
        )
    }

    func testIndexFindingsMergeOnHashMatchAndDropOnEdit() async {
        let service = service()
        let text = "func orphan() {}\n"
        XCTAssertTrue(service.analysis(of: text, url: file).findings.isEmpty, "the editor's pass does not search the project")
        await service.runIndexInspections(for: file, text: text)
        XCTAssertEqual(
            service.analysis(of: text, url: file).findings.map(\.id), ["unused-declaration"],
            "the saved text merges the stored finding"
        )
        let edited = "// touched\nfunc orphan() {}\n"
        XCTAssertTrue(
            service.analysis(of: edited, url: file).findings.isEmpty,
            "the next edit drops the finding: the hash no longer matches"
        )
    }

    func testStaleEntryShowsShiftedMarkersInsteadOfFlickering() async {
        let service = service()
        let provider = SwiftInspectionDiagnosticProvider(service: service)
        let text = "func orphan() {}\n"
        await service.runIndexInspections(for: file, text: text)
        let fresh = await provider.diagnosticsWithFreshness(for: document(text))
        XCTAssertEqual(fresh.diagnostics.map(\.code), ["unused-declaration"])
        XCTAssertTrue(fresh.staleSources.isEmpty)
        // The edit appends a line, so the stored offsets still point at the declaration:
        // the marker stays (flagged stale) instead of flickering until the next save.
        let edited = text + "// typed\n"
        let stale = await provider.diagnosticsWithFreshness(for: document(edited))
        XCTAssertEqual(stale.diagnostics.map(\.code), ["unused-declaration"])
        XCTAssertEqual(stale.diagnostics.first?.range.start.line, 0)
        XCTAssertEqual(stale.staleSources, [SwiftInspection.diagnosticSource])
        let plain = await provider.diagnostics(for: document(edited))
        XCTAssertTrue(plain.isEmpty, "the plain pass shows only the current text")
    }

    func testACancelledPassStoresNothing() async {
        let service = service()
        let text = "func orphan() {}\n"
        await cancelledRun(service, url: file, text: text)
        XCTAssertTrue(service.analysis(of: text, url: file).findings.isEmpty)
    }

    /// Runs the pass already cancelled: the closure takes only parameters, so it captures nothing
    /// of the test. Cancellation is cooperative — the pipeline still runs, but the post-pass guard
    /// drops the answer before it is stored or pushed.
    private func cancelledRun(_ service: SwiftInspectionService, url: URL, text: String) async {
        let pass = Task { await service.runIndexInspections(for: url, text: text) }
        pass.cancel()
        await pass.value
    }

    func testADisabledIndexRuleSkipsThePassAndClearsStoredFindings() async {
        // The options closure reads the box, so the rule going off takes effect at once.
        let box = OptionsBox(SwiftInspectionOptions())
        let service = service(box: box)
        let text = "func orphan() {}\n"
        await service.runIndexInspections(for: file, text: text)
        XCTAssertEqual(service.analysis(of: text, url: file).findings.map(\.id), ["unused-declaration"])
        var off = box.options
        off.disabled = [SwiftInspectionRule.unusedDeclaration.code]
        box.options = off
        await service.runIndexInspections(for: file, text: text)
        XCTAssertTrue(service.analysis(of: text, url: file).findings.isEmpty)
    }

    func testThePassPushesItsDiagnosticsThroughTheResultHandler() async {
        let pushed = Pushed()
        let service = service(pushed: pushed)
        let text = "func orphan() {}\n"
        await service.runIndexInspections(for: file, text: text)
        XCTAssertEqual(pushed.values.count, 1)
        XCTAssertEqual(pushed.values.first?.0.standardizedFileURL, file.standardizedFileURL)
        XCTAssertEqual(pushed.values.first?.1.map(\.code), ["unused-declaration"])
    }
}
