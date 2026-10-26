import EditorIntelligence
import Foundation
import XCTest

@testable import Umbra

/// `@` in a Markdown file offers project files, and "Run with Agent" builds its prompt from the buffer.
final class MarkdownFileMentionCompletionTests: XCTestCase {
    private let files = ["src/ui/MainView.swift", "docs/My Notes/Plan.md", "README.md"]

    private func context(_ source: String, language: String? = "markdown") -> CompletionContext {
        let marker = source.range(of: "€")!
        let text = source.replacingOccurrences(of: "€", with: "")
        let offset = source.utf16.distance(from: source.utf16.startIndex, to: marker.lowerBound.samePosition(in: source.utf16)!)
        let lines = String(text.utf16.prefix(offset))!.components(separatedBy: "\n")
        let position = TextPosition(line: lines.count - 1, column: (lines.last ?? "").utf16.count, utf16Offset: offset)
        let document = Document(
            id: DocumentID(), url: nil, displayName: "prompt.md", contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: TextRange(start: position, end: position)), cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100), languageIdentifier: language)
        return makeCompletionContext(document: document, trigger: .keystroke("@"))
    }

    private func provider() -> MarkdownFileMentionCompletionProvider {
        let files = files
        return MarkdownFileMentionCompletionProvider(source: { _, limit in Array(files.prefix(limit)) })
    }

    func testOffersFilesRightAfterAnAtSignAndInsertsTheirPaths() async {
        let provider = provider()
        let atStart = context("@€")
        XCTAssertTrue(provider.isPrimary(for: atStart))
        let items = await provider.provide(context: atStart)
        XCTAssertEqual(items.map(\.label), ["MainView.swift", "Plan.md", "README.md"])
        XCTAssertEqual(items.first?.insertText, "src/ui/MainView.swift")
        XCTAssertEqual(items.first?.detail, "src/ui")
        XCTAssertEqual(items.first?.kind, .file)

        let typed = context("Look at @Ma€")
        XCTAssertTrue(provider.isPrimary(for: typed))
        let range = typed.range
        XCTAssertEqual(range.end.utf16Offset - range.start.utf16Offset, 2, "the typed fragment is what the path replaces")
        let typedItems = await provider.provide(context: typed)
        XCTAssertFalse(typedItems.isEmpty)
    }

    func testAPathWithSpacesIsInsertedInTheQuotedForm() async {
        let items = await provider().provide(context: context("@€"))
        XCTAssertEqual(items.first(where: { $0.label == "Plan.md" })?.insertText, "\"docs/My Notes/Plan.md\"")
        XCTAssertEqual(MarkdownFileMentionCompletionProvider.insertion(for: "a.md"), "a.md")
    }

    func testEmailsOtherLanguagesAndPlainWordsAreLeftAlone() async {
        let provider = provider()
        for source in ["mail me@exa€", "just text€"] {
            let ctx = context(source)
            XCTAssertFalse(provider.isPrimary(for: ctx), source)
            let items = await provider.provide(context: ctx)
            XCTAssertTrue(items.isEmpty, source)
        }
        let java = context("@€", language: "java")
        XCTAssertFalse(provider.isPrimary(for: java))
        let javaItems = await provider.provide(context: java)
        XCTAssertTrue(javaItems.isEmpty)
    }

    func testItNeverReturnsMoreThanTheLimitAndNeedsASource() async {
        let many = (0..<100).map { "dir/File\($0).md" }
        let capped = MarkdownFileMentionCompletionProvider(source: { _, _ in many })
        let cappedItems = await capped.provide(context: context("@€"))
        XCTAssertEqual(cappedItems.count, MarkdownFileMentionCompletionProvider.limit)

        let none = MarkdownFileMentionCompletionProvider()
        let noneItems = await none.provide(context: context("@€"))
        XCTAssertTrue(noneItems.isEmpty)
    }
}

final class IDEAgentMarkdownRunPromptTests: XCTestCase {
    func testASelectionWinsOverTheFile() {
        XCTAssertEqual(IDEAgentPrompts.markdownRun(text: "# Title\n\nwhole file", selection: "  just this @A.md  \n"), "just this @A.md")
    }

    func testWithoutASelectionTheWholeFileIsSentWithoutItsFrontmatter() {
        let text = "---\nname: review\n---\n\n# Review\n\nRead @src/A.java and list bugs.\n"
        XCTAssertEqual(IDEAgentPrompts.markdownRun(text: text, selection: nil), "# Review\n\nRead @src/A.java and list bugs.")
        XCTAssertEqual(IDEAgentPrompts.markdownRun(text: "no header\n", selection: ""), "no header")
    }

    func testABlankSelectionFallsBackToTheFileAndAnEmptyFileSendsNothing() {
        XCTAssertEqual(IDEAgentPrompts.markdownRun(text: "body", selection: "  \n"), "body")
        XCTAssertNil(IDEAgentPrompts.markdownRun(text: "  \n\n", selection: nil))
        XCTAssertNil(IDEAgentPrompts.markdownRun(text: "---\nname: x\n---\n", selection: nil), "frontmatter alone is not a prompt")
    }
}

@MainActor
final class IDEAgentMarkdownRunWorkspaceTests: XCTestCase {
    private var project: URL!
    private var workspace: IDEWorkspace!

    override func setUpWithError() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        project = FileManager.default.temporaryDirectory.appendingPathComponent("agent-md-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        workspace = IDEWorkspace()
        workspace.project.setRoot(project)
        workspace.bootstrap()
    }

    override func tearDownWithError() throws {
        workspace.teardown()
        try? FileManager.default.removeItem(at: project)
    }

    func testOnlyAMarkdownTabCanRunAndItSendsTheLiveSelectionOrBuffer() async throws {
        let java = project.appendingPathComponent("A.java")
        try "class A {}\n".write(to: java, atomically: true, encoding: .utf8)
        await workspace.openDocument(from: java)
        XCTAssertFalse(workspace.canRunMarkdownWithAgent)
        XCTAssertNil(workspace.activeMarkdownRunPrompt())

        let markdown = project.appendingPathComponent("prompt.md")
        try "---\ntitle: t\n---\nSummarize @A.java\n".write(to: markdown, atomically: true, encoding: .utf8)
        await workspace.openDocument(from: markdown)
        XCTAssertTrue(workspace.canRunMarkdownWithAgent)
        XCTAssertEqual(workspace.activeMarkdownRunPrompt(), "Summarize @A.java")

        let textView = workspace.host(for: workspace.workbench.activePaneID).textView
        let text = (textView.text as NSString)
        textView.selectedRange = text.range(of: "Summarize")
        XCTAssertEqual(workspace.activeMarkdownRunPrompt(), "Summarize")
    }

    func testTheContextMenuOffersRunWithAgentForMarkdownEvenWithoutASelection() async throws {
        let markdown = project.appendingPathComponent("prompt.md")
        try "hello\n".write(to: markdown, atomically: true, encoding: .utf8)
        await workspace.openDocument(from: markdown)
        let textView = workspace.host(for: workspace.workbench.activePaneID).textView
        let items = workspace.agentContextMenuItems(
            context: .init(location: 0, selectedRange: NSRange(location: 0, length: 0)), textView: textView, url: markdown)
        XCTAssertEqual(items.last?.title, "Run with Agent")
    }
}
