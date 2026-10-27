import EditorIntelligence
import EditorIntelligenceLSP
import Foundation
import JavaIntelligence
import XCTest

/// The semantic ceiling for the Swift completion corpus (`docs/SWIFT_INTELLIGENCE_ROADMAP.md`, Phase 0):
/// every case in `Fixtures/SwiftCorpus/cases` is opened as a real file in a real `sourcekit-lsp`
/// and asked for completions at the caret, then judged by the same `//!` directives the native run
/// uses. The native column is `Fixtures/SwiftCorpus/baseline.json` (the cases that pass natively), so
/// the report says how far the native tier is from the compiler, and which cases only it answers.
///
/// Runs only with `SWIFT_PARITY=1`, and skips without `sourcekit-lsp`. The files sit in a folder with
/// no `Package.swift`, so the server uses its fallback build settings: one module per file, the
/// default SDK. `UPDATE_SWIFT_PARITY_BASELINE=1` writes `sourcekit-baseline.json` beside the native
/// one, which `SwiftParityCorpusTests` reads for `docs/SWIFT_PARITY.md`. The SourceKit column is
/// reported and recorded but never ratcheted: it depends on the installed toolchain.
final class SwiftSourceKitCeilingTests: XCTestCase {
    struct CeilingBaseline: Codable {
        var toolchain: String
        var passing: [String]
        /// Cases that failed on a list the server marked incomplete and that name no word to type
        /// (`LSPCompletionList.isIncomplete`), so the answer may lie past the page and the case proves nothing.
        var inconclusive: [String]
    }

    /// sourcekit-lsp returns at most this many items for one request.
    static let serverPageSize = 200

    static var corpusRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/SwiftCorpus")
    }

    static var baselineURL: URL { corpusRoot.appendingPathComponent("sourcekit-baseline.json") }

    func testSourceKitCompletionCeiling() async throws {
        guard ProcessInfo.processInfo.environment["SWIFT_PARITY"] == "1" else {
            throw XCTSkip("The semantic ceiling runs only with SWIFT_PARITY=1")
        }
        let server = try SourceKitProcess.discover()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-sourcekit-ceiling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var cases = try CompletionCorpusRunner.Case.load(
            from: Self.corpusRoot.appendingPathComponent("cases"), extension: "swift"
        )
        if let only = ProcessInfo.processInfo.environment["SWIFT_PARITY_CASE"] {
            cases = cases.filter { $0.name.hasPrefix(only) }
            XCTAssertFalse(cases.isEmpty, "no case matches SWIFT_PARITY_CASE=\(only)")
        }
        let nativePassing = Set(CompletionCorpusRunner.Baseline.load(from: Self.corpusRoot.appendingPathComponent("baseline.json"))?.passing ?? [])

        let session = try server.start(root: root)
        defer { session.stop() }

        var rows: [Row] = []
        for corpusCase in cases {
            let url = root.appendingPathComponent("\(corpusCase.name).swift")
            try corpusCase.text.write(to: url, atomically: true, encoding: .utf8)
            let placed = CompletionCorpusRunner.Case(
                name: corpusCase.name, url: url, text: corpusCase.text,
                caretUTF16Offset: corpusCase.caretUTF16Offset, directives: corpusCase.directives
            )
            rows.append(await run(placed, session: session, nativePasses: nativePassing.contains(placed.name)))
        }

        let report = Self.render(rows: rows, toolchain: server.toolchain)
        print(report)
        try? report.write(
            to: FileManager.default.temporaryDirectory.appendingPathComponent("swift-sourcekit-ceiling.txt"),
            atomically: true, encoding: .utf8
        )
        XCTAssertFalse(rows.allSatisfy { $0.items == 0 }, "sourcekit-lsp answered no completion at all")

        if ProcessInfo.processInfo.environment["SWIFT_PARITY_CASE"] == nil,
           ProcessInfo.processInfo.environment["UPDATE_SWIFT_PARITY_BASELINE"] == "1" {
            let baseline = CeilingBaseline(
                toolchain: server.toolchain,
                passing: rows.filter(\.sourceKitPasses).map(\.name).sorted(),
                inconclusive: rows.filter(\.isInconclusive).map(\.name).sorted()
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(baseline).write(to: Self.baselineURL)
        }
    }

    // MARK: - Progress

    /// Background indexing of a real SwiftPM package reaches the client as `$/progress`, with no
    /// option set: this is what Umbra's status bar shows. Skipped without `SWIFT_PARITY=1`.
    func testSourceKitReportsBackgroundIndexingProgress() async throws {
        guard ProcessInfo.processInfo.environment["SWIFT_PARITY"] == "1" else {
            throw XCTSkip("Runs only with SWIFT_PARITY=1")
        }
        let server = try SourceKitProcess.discover()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-sourcekit-progress-\(UUID().uuidString)", isDirectory: true)
        let sources = root.appendingPathComponent("Sources/Lib", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = "// swift-tools-version:5.9\nimport PackageDescription\n"
            + "let package = Package(name: \"Lib\", targets: [.target(name: \"Lib\")])\n"
        try manifest.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "public struct Box { public var width = 1\n    public init() {}\n}\n"
            .write(to: sources.appendingPathComponent("Box.swift"), atomically: true, encoding: .utf8)
        let text = "func use(box: Box) {\n    box.\n}\n"
        let url = sources.appendingPathComponent("Use.swift")
        try text.write(to: url, atomically: true, encoding: .utf8)

        let log = ProgressRecorder()
        let session = try server.start(root: root, onProgress: { log.append($0.map(\.summary)) })
        defer { session.stop() }

        let position = TextPosition(line: 1, column: 8, utf16Offset: 28)
        let document = Document(
            url: url, displayName: "Use.swift",
            contentSnapshot: TextSnapshot(version: 1, text: text),
            selection: Selection(range: EditorIntelligence.TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 800, height: 600),
            languageIdentifier: "swift"
        )
        await session.client.notifyOpened(document, languageID: "swift", version: 1)
        _ = try? await session.client.requestCompletions(for: document, at: position)

        // Indexing starts after the workspace loads and ends on its own; wait for work to begin and finish.
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            let seen = log.snapshot
            if seen.contains(where: { !$0.isEmpty }), seen.last?.isEmpty == true { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        let seen = log.snapshot
        print("sourcekit-lsp progress (\(seen.count) updates): \(seen.map { $0.joined(separator: " | ") })")
        XCTAssertTrue(seen.contains { !$0.isEmpty }, "sourcekit-lsp sent no work-done progress while indexing a package")
        XCTAssertEqual(seen.last, [], "the last update is the end of the work")
    }

    // MARK: - Document sync

    /// The server answers from the editor's buffer, not the file on disk, and follows a later edit.
    /// The disk holds `Box` with `width`; the buffer adds `height`, then `depth`. Without
    /// `LSPWorkspaceDocumentSync` the server has never been sent the file and answers every request
    /// with "No language service found".
    func testTheServerAnswersFromTheSyncedBufferAndFollowsEdits() async throws {
        guard ProcessInfo.processInfo.environment["SWIFT_PARITY"] == "1" else {
            throw XCTSkip("Runs only with SWIFT_PARITY=1")
        }
        let server = try SourceKitProcess.discover()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-sourcekit-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Box.swift")
        try "struct Box { var width = 1 }\n".write(to: url, atomically: true, encoding: .utf8)

        let session = try server.start(root: root)
        defer { session.stop() }

        func buffer(_ members: String, id: DocumentID) -> Document {
            let text = "struct Box { var width = 1\(members) }\nlet b = Box()\nb.\n"
            let origin = TextPosition(line: 0, column: 0, utf16Offset: 0)
            return Document(
                id: id, url: url, displayName: "Box.swift",
                contentSnapshot: TextSnapshot(version: 0, text: text),
                selection: Selection(range: EditorIntelligence.TextRange(start: origin, end: origin)),
                cursor: Cursor(position: origin), viewport: Viewport(x: 0, y: 0, width: 800, height: 600),
                languageIdentifier: "swift"
            )
        }
        func completions(_ document: Document) async -> [String] {
            let position = TextPosition(line: 2, column: 2, utf16Offset: 0)
            let items = (try? await session.client.requestCompletions(for: document, at: position)) ?? []
            return items.map(Self.bareName(of:))
        }
        func waitFor(_ member: String, in document: Document) async -> [String] {
            var names: [String] = []
            for _ in 0..<40 {
                names = await completions(document)
                if names.contains(member) { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            return names
        }

        let id = DocumentID()
        let workspace = Workspace()
        await workspace.openDocument(buffer("; var height = 2", id: id))
        let sync = LSPWorkspaceDocumentSync(client: session.client, languages: ["swift"])
        await sync.start(workspace: workspace)
        defer { Task { await sync.stop() } }

        let first = await waitFor("height", in: buffer("; var height = 2", id: id))
        XCTAssertTrue(first.contains("width"), "the member on disk: \(first.prefix(12))")
        XCTAssertTrue(first.contains("height"), "a member only the buffer has: \(first.prefix(12))")

        // The outline reads the document itself. Completion cannot show the edit here: SourceKit-LSP hands
        // back its open completion session for a request at the same position, whatever changed above it.
        func members(of document: Document) async -> [String] {
            let symbols = (try? await session.client.requestDocumentSymbols(for: document)) ?? []
            func names(_ items: [LSPOutlineSymbol]) -> [String] { items.flatMap { [$0.name] + names($0.children) } }
            return names(symbols)
        }
        let edited = buffer("; var depth = 3", id: id)
        await workspace.updateDocument(edited)
        var outline: [String] = []
        for _ in 0..<40 {
            outline = await members(of: edited)
            if outline.contains("depth") { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        XCTAssertTrue(outline.contains("depth"), "a member added after the file was opened: \(outline)")
        XCTAssertFalse(outline.contains("height"), "a member the edit removed: \(outline)")
    }

    // MARK: - SDK interfaces

    /// Go to Definition on an SDK type lands in a generated interface that the app treats as a read-only
    /// dependency, and once that file is open and synced the server answers inside it (hover, and
    /// Go to Definition from there). This client does not opt in to `sourcekit-lsp://` documents, so the
    /// server writes the interface to disk and returns a plain `file://` location.
    func testGoToDefinitionIntoTheSDKLandsInAnInterfaceTheServerCanAnswerInside() async throws {
        guard ProcessInfo.processInfo.environment["SWIFT_PARITY"] == "1" else {
            throw XCTSkip("Runs only with SWIFT_PARITY=1")
        }
        let server = try SourceKitProcess.discover()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-sourcekit-interface-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = "let name: String = \"x\"\nprint(name.count)\n"
        let url = root.appendingPathComponent("Use.swift")
        try text.write(to: url, atomically: true, encoding: .utf8)

        func document(_ url: URL, _ text: String) -> Document {
            let origin = TextPosition(line: 0, column: 0, utf16Offset: 0)
            return Document(
                url: url, displayName: url.lastPathComponent,
                contentSnapshot: TextSnapshot(version: 0, text: text),
                selection: Selection(range: EditorIntelligence.TextRange(start: origin, end: origin)),
                cursor: Cursor(position: origin), viewport: Viewport(x: 0, y: 0, width: 800, height: 600),
                languageIdentifier: "swift"
            )
        }
        let session = try server.start(root: root)
        defer { session.stop() }
        let workspace = Workspace()
        let source = document(url, text)
        await workspace.openDocument(source)
        let sync = LSPWorkspaceDocumentSync(client: session.client, languages: ["swift"])
        await sync.start(workspace: workspace)
        defer { Task { await sync.stop() } }

        // `String` in `let name: String`.
        let atString = TextPosition(line: 0, column: 11, utf16Offset: 11)
        var locations: [LSPLocation] = []
        for _ in 0..<40 where locations.isEmpty {
            locations = (try? await session.client.requestDefinition(for: source, at: atString)) ?? []
            if locations.isEmpty { try await Task.sleep(nanoseconds: 250_000_000) }
        }
        let target = try XCTUnwrap(locations.first, "no definition for String")
        let interfaceURL = try XCTUnwrap(URL(string: target.uri))
        print("definition of String: \(interfaceURL.path) line \(target.range.start.line)")
        XCTAssertTrue(DependencySourceLocation.isGeneratedInterface(interfaceURL), "\(interfaceURL.path)")
        XCTAssertEqual(interfaceURL.pathExtension, "swiftinterface")

        // Opened as a tab would be (the language comes from the extension) and synced.
        let interface = document(interfaceURL, try String(contentsOf: interfaceURL, encoding: .utf8))
        XCTAssertTrue(interface.isDependencySource, "the app must not check or edit it")
        await workspace.openDocument(interface)
        let inside = TextPosition(line: target.range.start.line, column: target.range.start.character + 2, utf16Offset: 0)
        var hover: LSPHover?
        for _ in 0..<40 where hover == nil {
            hover = try? await session.client.requestHover(for: interface, at: inside)
            if hover == nil { try await Task.sleep(nanoseconds: 250_000_000) }
        }
        XCTAssertTrue(hover?.contents.contains("String") == true, "hover inside the interface: \(hover?.contents.prefix(80) ?? "nil")")
        let further = (try? await session.client.requestDefinition(for: interface, at: inside)) ?? []
        XCTAssertFalse(further.isEmpty, "Go to Definition from inside the interface")
    }

    // MARK: - Fix-its

    /// A compiler warning with a fix-it comes back from `textDocument/codeAction` as a `quickfix` with
    /// the edit that applies it. Asked once with the diagnostic in the request context (what Umbra
    /// sends) and once without, to know whether the server depends on it.
    func testSourceKitOffersCompilerFixItsAsQuickFixes() async throws {
        guard ProcessInfo.processInfo.environment["SWIFT_PARITY"] == "1" else {
            throw XCTSkip("Runs only with SWIFT_PARITY=1")
        }
        let server = try SourceKitProcess.discover()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-sourcekit-fixit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = "func f() {\n    var count = 1\n    print(count)\n}\n"
        let url = root.appendingPathComponent("FixIt.swift")
        try text.write(to: url, atomically: true, encoding: .utf8)

        let session = try server.start(root: root)
        defer { session.stop() }
        let origin = TextPosition(line: 0, column: 0, utf16Offset: 0)
        let document = Document(
            url: url, displayName: "FixIt.swift",
            contentSnapshot: TextSnapshot(version: 1, text: text),
            selection: Selection(range: EditorIntelligence.TextRange(start: origin, end: origin)),
            cursor: Cursor(position: origin),
            viewport: Viewport(x: 0, y: 0, width: 800, height: 600),
            languageIdentifier: "swift"
        )
        await session.client.notifyOpened(document, languageID: "swift", version: 1)

        var diagnostics: [LSPDiagnostic] = []
        let deadline = Date().addingTimeInterval(30)
        while diagnostics.isEmpty, Date() < deadline {
            diagnostics = (try? await session.client.requestDiagnostics(for: document)) ?? []
            if diagnostics.isEmpty { try await Task.sleep(nanoseconds: 250_000_000) }
        }
        let diagnostic = try XCTUnwrap(diagnostics.first, "sourcekit-lsp published no diagnostic for a never-mutated var")
        print("fix-it diagnostic: \(diagnostic.message) at \(diagnostic.range.start.line):\(diagnostic.range.start.character)")
        let position = TextPosition(
            line: diagnostic.range.start.line, column: diagnostic.range.start.character, utf16Offset: 15
        )

        let withContext = try await session.client.requestCodeActions(for: document, at: position, diagnostics: [diagnostic])
        let withoutContext = try await session.client.requestCodeActions(for: document, at: position, diagnostics: [])
        print("code actions with context: \(withContext.map { "\($0.kind ?? "-"): \($0.title) [\($0.edits.count) edits]" })")
        print("code actions without context: \(withoutContext.map { "\($0.kind ?? "-"): \($0.title) [\($0.edits.count) edits]" })")

        let fix = withContext.first { $0.kind == "quickfix" && !$0.edits.isEmpty }
        XCTAssertNotNil(fix, "no quickfix with an edit came back for \(diagnostic.message)")
        XCTAssertEqual(fix?.edits.first?.newText, "let", "the fix-it turns the var into a let")

        // The path Umbra takes: the server's diagnostic becomes an editor `Diagnostic`, goes back into the
        // request context through `LSPCodeActionProvider`, and the answer is an editor `CodeAction`.
        let box = LSPConnectionBox(client: session.client)
        box.setSupportedFeatures(await session.client.advertisedFeatures())
        let service = LSPLanguageService(
            configuration: LSPLanguageConfiguration(
                name: "SourceKit-LSP", languageIdentifiers: ["swift"],
                enabledFeatures: [.codeActions, .diagnostics], diagnosticSource: .sourceKitLSP
            ),
            connections: box
        )
        var editorDiagnostics: [EditorIntelligence.Diagnostic] = []
        for provider in service.providers.diagnostics where editorDiagnostics.isEmpty {
            editorDiagnostics = await provider.diagnostics(for: document)
        }
        let editorDiagnostic = try XCTUnwrap(editorDiagnostics.first, "the service published no diagnostic")
        let provider = try XCTUnwrap(service.providers.codeActions)
        let editorActions = await provider.codeActions(for: document, at: editorDiagnostic.range.start, diagnostics: editorDiagnostics)
        print("editor code actions: \(editorActions.map { "\($0.kind ?? "-"): \($0.title)" })")
        let editorFix = editorActions.first { $0.kind == "quickfix" }
        XCTAssertEqual(editorFix?.title, "Replace 'var' with 'let'")
        XCTAssertEqual(editorFix?.edits.first?.replacement, "let")
    }

    // MARK: - One case

    struct Row {
        let name: String
        let gap: String?
        let nativePasses: Bool
        let sourceKitPasses: Bool
        let items: Int
        let failure: String
        let top: [String]
        /// The server marked its list incomplete: it stopped at a page.
        let isIncomplete: Bool
        /// The case named something the page left out, and the harness typed the start of each such name
        /// and asked again, as a user does.
        let attemptedNarrowing: Bool

        /// A failure on an incomplete list that typing could not settle (the case names no word to type,
        /// as `excludes` and `top1` do not), so it proves nothing either way.
        var isInconclusive: Bool { !sourceKitPasses && isIncomplete && !attemptedNarrowing }
    }

    private func run(_ corpusCase: CompletionCorpusRunner.Case, session: SourceKitSession, nativePasses: Bool) async -> Row {
        let document = corpusCase.document(language: "swift")
        let position = document.cursor.position
        await session.client.notifyOpened(document, languageID: "swift", version: 1)
        var list = LSPCompletionList(items: [], isIncomplete: false)
        // The first request into a file can land before the server has its settings; ask again.
        for attempt in 0..<4 {
            list = (try? await session.client.requestCompletionList(for: document, at: position)) ?? list
            if !list.items.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(400 * (attempt + 1)))
        }

        let range = EditorIntelligence.TextRange(start: position, end: position)
        let ordered = list.items.enumerated()
            .sorted { ($0.element.sortText ?? "", $0.offset) < ($1.element.sortText ?? "", $1.offset) }
            .map(\.element)
        var items = ordered.map { item in
            CompletionItem(
                label: Self.bareName(of: item), insertText: item.insertText ?? item.label,
                kind: .text, range: range, source: "sourcekit-lsp"
            )
        }
        var result = CompletionCorpusRunner.Result(name: corpusCase.name)
        CompletionCorpusRunner.checkLabels(corpusCase, ranked: items, into: &result)

        // A page the server marked incomplete says nothing about names beyond it. Type the start of each
        // missing name and ask again; a name that then appears was there all along.
        var attemptedNarrowing = false
        if !result.passes, list.isIncomplete {
            let present = Set(items.map(\.label))
            let missing = CompletionCorpusRunner.list(corpusCase.directives["contains"] ?? "").filter { !present.contains($0) }
            if !missing.isEmpty {
                attemptedNarrowing = true
                for name in missing where await Self.completes(name, in: corpusCase, document: document, session: session) {
                    items.append(CompletionItem(label: name, insertText: name, kind: .text, range: range, source: "sourcekit-lsp"))
                }
                result = CompletionCorpusRunner.Result(name: corpusCase.name)
                CompletionCorpusRunner.checkLabels(corpusCase, ranked: items, into: &result)
            }
        }
        await session.client.notifyClosed(documentID: document.id)
        return Row(
            name: corpusCase.name, gap: corpusCase.directives["gap"], nativePasses: nativePasses,
            sourceKitPasses: result.passes, items: items.count,
            failure: (result.hardFailures + result.scoredFailures).joined(separator: "; "),
            top: items.prefix(8).map(\.label),
            isIncomplete: list.isIncomplete, attemptedNarrowing: attemptedNarrowing
        )
    }

    /// Whether the server offers `name` once the first three characters of it are typed at the caret.
    /// The document is closed and opened again with the typed text: SourceKit-LSP hands back its open
    /// completion session for a request at an unmoved position, and two names typed in turn land on the
    /// same one.
    private static func completes(
        _ name: String, in corpusCase: CompletionCorpusRunner.Case, document: Document, session: SourceKitSession
    ) async -> Bool {
        let typed = String(name.prefix(3))
        let text = (corpusCase.text as NSString).replacingCharacters(
            in: NSRange(location: corpusCase.caretUTF16Offset, length: 0), with: typed
        )
        let offset = corpusCase.caretUTF16Offset + (typed as NSString).length
        let position = CompletionCorpusRunner.position(in: text, utf16Offset: offset)
        let typedDocument = Document(
            id: document.id, url: document.url, displayName: document.displayName,
            contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: EditorIntelligence.TextRange(start: position, end: position)),
            cursor: Cursor(position: position), viewport: document.viewport, languageIdentifier: "swift"
        )
        await session.client.notifyClosed(documentID: document.id)
        await session.client.notifyOpened(typedDocument, languageID: "swift", version: 1)
        let list = (try? await session.client.requestCompletionList(for: typedDocument, at: position))
            ?? LSPCompletionList(items: [], isIncomplete: false)
        return list.items.contains { bareName(of: $0) == name }
    }

    /// SourceKit labels carry the signature (`append(_ newElement: Int)`); the corpus names a member
    /// by its base name, as the native tier does. A label that is itself the name (`from:`) is kept.
    static func bareName(of item: LSPCompletionItem) -> String {
        let source = item.filterText ?? item.label
        let trimmed = source.hasPrefix(".") ? String(source.dropFirst()) : source
        if let paren = trimmed.firstIndex(of: "(") { return String(trimmed[..<paren]) }
        return trimmed
    }

    // MARK: - Report

    static func render(rows: [Row], toolchain: String) -> String {
        let native = rows.filter(\.nativePasses).count
        let sourceKit = rows.filter(\.sourceKitPasses).count
        var lines = [
            "Swift completion ceiling (sourcekit-lsp, \(toolchain))",
            "cases \(rows.count) | native passes \(native) | sourcekit passes \(sourceKit) | both \(rows.filter { $0.nativePasses && $0.sourceKitPasses }.count)",
        ]
        let conclusive = rows.filter { !$0.isInconclusive }
        let onlyNative = conclusive.filter { $0.nativePasses && !$0.sourceKitPasses }
        let onlySourceKit = conclusive.filter { !$0.nativePasses && $0.sourceKitPasses }
        let neither = conclusive.filter { !$0.nativePasses && !$0.sourceKitPasses }
        lines.append("inconclusive, incomplete list with no word to type (\(rows.filter(\.isInconclusive).count)): \(rows.filter(\.isInconclusive).map(\.name).joined(separator: ", "))")
        lines.append("narrowed by typing (\(rows.filter(\.attemptedNarrowing).count)): \(rows.filter(\.attemptedNarrowing).map { "\($0.name)[\($0.sourceKitPasses ? "found" : "absent")]" }.joined(separator: ", "))")
        lines.append("only native (\(onlyNative.count)): \(onlyNative.map(\.name).joined(separator: ", "))")
        lines.append("only sourcekit (\(onlySourceKit.count)): \(onlySourceKit.map { "\($0.name)[\($0.gap ?? "-")]" }.joined(separator: ", "))")
        lines.append("neither (\(neither.count)): \(neither.map(\.name).joined(separator: ", "))")
        for row in rows where !row.sourceKitPasses {
            lines.append("SOURCEKIT FAIL \(row.name) (items \(row.items)): \(row.failure) | top: \(row.top.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - The server process

/// `sourcekit-lsp` found through `xcrun`. Skips (rather than fails) without one.
struct SourceKitProcess {
    let executable: URL
    let toolchain: String

    static func discover() throws -> SourceKitProcess {
        let found = Process()
        found.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        found.arguments = ["--find", "sourcekit-lsp"]
        let pipe = Pipe()
        found.standardOutput = pipe
        found.standardError = Pipe()
        do { try found.run() } catch { throw XCTSkip("xcrun is unavailable") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        found.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard found.terminationStatus == 0, FileManager.default.isExecutableFile(atPath: path) else {
            throw XCTSkip("No sourcekit-lsp on this machine")
        }
        let versionText = (try? SwiftParityOracle.discover().version) ?? "unknown"
        return SourceKitProcess(executable: URL(fileURLWithPath: path), toolchain: "Swift \(versionText)")
    }

    func start(root: URL, onProgress: (@Sendable ([LSPWorkProgress]) -> Void)? = nil) throws -> SourceKitSession {
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = root
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let (stream, continuation) = AsyncStream<Data>.makeStream()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
            } else {
                continuation.yield(data)
            }
        }
        try process.run()
        let writer = input.fileHandleForWriting
        let client = LanguageServerClient.make(
            write: { data in try writer.write(contentsOf: data) },
            read: stream,
            documentURI: { $0.url?.absoluteString ?? "untitled:\($0.id)" },
            workspaceRoot: root,
            onProgress: onProgress
        )
        return SourceKitSession(process: process, client: client, input: input, output: output)
    }
}

final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [[String]] = []
    func append(_ entry: [String]) {
        lock.lock()
        entries.append(entry)
        lock.unlock()
    }
    var snapshot: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

final class SourceKitSession: @unchecked Sendable {
    let client: LanguageServerClient
    private let process: Process
    private let input: Pipe
    private let output: Pipe

    init(process: Process, client: LanguageServerClient, input: Pipe, output: Pipe) {
        self.process = process
        self.client = client
        self.input = input
        self.output = output
    }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}
