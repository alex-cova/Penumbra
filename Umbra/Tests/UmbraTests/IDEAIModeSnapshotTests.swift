import AgentKit
import AppKit
import SwiftUI
import XCTest
@testable import Umbra

/// Answers Ollama's model list from memory.
private final class SheetTransport: LLMTransport, @unchecked Sendable {
    func open(_ request: URLRequest) async throws -> LLMHTTPResponse {
        let (status, data) = try await fetch(request)
        return LLMHTTPResponse(status: status, lines: AsyncThrowingStream { continuation in
            continuation.yield(String(decoding: data, as: UTF8.self))
            continuation.finish()
        })
    }

    func fetch(_ request: URLRequest) async throws -> (status: Int, data: Data) {
        switch request.url?.path {
        case "/api/tags":
            return (200, Data(#"{"models":[{"name":"qwen3:8b","size":5200000000,"details":{"parameter_size":"8.2B","quantization_level":"Q4_K_M"}},{"name":"llama3.2:1b","size":1300000000,"details":{"parameter_size":"1.2B","quantization_level":"Q8_0"}}]}"#.utf8))
        case "/api/show":
            let body = (try? JSONValue(parsing: String(decoding: request.httpBody ?? Data(), as: UTF8.self))) ?? .null
            let tools = body["model"]?.stringValue == "qwen3:8b"
            return (200, Data((tools ? #"{"capabilities":["completion","tools","thinking"]}"# : #"{"capabilities":["completion"]}"#).utf8))
        default:
            return (404, Data())
        }
    }
}

/// Draws AI mode offscreen so its layout can be looked at. Writes PNGs only when `AI_MODE_PNG_DIR` is set;
/// otherwise it only checks that each view lays out to a real size.
@MainActor
final class IDEAIModeSnapshotTests: XCTestCase {
    private var workspace: IDEWorkspace!
    private var base: URL!

    override func setUpWithError() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        base = FileManager.default.temporaryDirectory.appendingPathComponent("ai-snap-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: base.appendingPathComponent("MyProject"), withIntermediateDirectories: true)
        workspace = IDEWorkspace()
        workspace.bootstrap()
    }

    override func tearDownWithError() throws {
        workspace.teardown()
        workspace = nil
        IDEWorkspace.isSessionPersistenceEnabled = true
        try? FileManager.default.removeItem(at: base)
    }

    private func render(_ name: String, width: CGFloat = 1100, height: CGFloat = 720) async throws {
        var sidebarWidth = 240.0
        var inspectorWidth = IDEAIInspector.defaultWidth
        let view = IDEAIModeView(
            sidebarWidth: Binding(get: { sidebarWidth }, set: { sidebarWidth = $0 }),
            inspectorWidth: Binding(get: { inspectorWidth }, set: { inspectorWidth = $0 }))
            .environment(workspace)
            .frame(width: width, height: height)
            .background(IDEAppearance.ColorToken.window)
            .preferredColorScheme(IDEAppearance.preferredColorScheme)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Let SwiftUI run its task and onAppear work. Sleeping (not spinning the run loop) lets the
        // main actor take the results of work a view started.
        try? await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.width, 0)
        guard let directory = ProcessInfo.processInfo.environment["AI_MODE_PNG_DIR"], let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    func testChatEmptyAndWithAConversation() async throws {
        workspace.showAIMode(tab: .chat)
        try await render("chat-empty")

        let settings = workspace.agent.settings
        settings.acceptDisclosure(for: .anthropic)
        let client = MockLLMClient(turns: [.text("Sure. Here is a **short** answer:\n\n```swift\nlet x: Int? = 1\n```\n\n- an optional holds a value or nothing\n- unwrap it with `if let`")])
        workspace.aiChat = IDEAIChatController(
            settings: settings, aiSettings: IDEAISettings(defaults: UserDefaults(suiteName: "snap.\(UUID())")!),
            store: nil, clientFactory: { _, _ in client })
        workspace.aiChat.choose(IDEAIModelChoice(provider: .anthropic, model: "claude-opus-5-5", reasoningEffort: "medium"))
        workspace.aiChat.selected.draft = "Explain optionals in Swift"
        workspace.aiChat.selected.send()
        for _ in 0..<300 where workspace.aiChat.selected.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(workspace.aiChat.selected.entries.count, 2)
        try await render("chat-conversation")
    }

    func testCodeWithASessionAndTheModelsSheet() async throws {
        workspace.openProjectFolder(base.appendingPathComponent("MyProject"))
        let settings = workspace.agent.settings
        settings.acceptDisclosure(for: .anthropic)
        settings.saveAPIKey("sk-ant-test", for: .anthropic)
        let client = MockLLMClient(turns: [.text("I read the project. It has no source files yet, so there is nothing to change.")])
        workspace.agent.choiceClientFactory = { _, _ in client }
        let choice = IDEAIModelChoice(provider: .anthropic, model: "claude-sonnet-5-5", reasoningEffort: "high")
        workspace.agent.newChatChoice = choice
        workspace.agent.selected.modelChoice = choice
        workspace.showAIMode(tab: .code)
        workspace.agent.draft = "What is in this project?"
        workspace.agent.send()
        for _ in 0..<300 where workspace.agent.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
        try await render("code-conversation")
    }

    func testCodeWithNoProjectAndWithAProject() async throws {
        workspace.showAIMode(tab: .code)
        try await render("code-no-project")

        workspace.openProjectFolder(base.appendingPathComponent("MyProject"))
        try await render("code-project-empty")
    }

    /// Code with its Changes, Plan and Browser panel open, after a run that edited a file and kept a checklist.
    func testTheChangesPlanAndBrowserPanel() async throws {
        let project = base.appendingPathComponent("MyProject")
        try "one\ntwo\nthree\n".write(to: project.appendingPathComponent("A.txt"), atomically: true, encoding: .utf8)
        workspace.openProjectFolder(project)
        let settings = workspace.agent.settings
        settings.acceptDisclosure(for: .anthropic)
        settings.saveAPIKey("sk-ant-test", for: .anthropic)
        let client = MockLLMClient(turns: [
            .toolCalls((id: "t", name: "todo", arguments: #"{"items":["[x] Read A.txt","[~] Change the second line","[ ] Run the tests"]}"#)),
            .toolCalls((id: "r", name: "read_file", arguments: #"{"path":"A.txt"}"#)),
            .toolCalls((id: "e", name: "edit_file", arguments: #"{"path":"A.txt","old_string":"two","new_string":"2"}"#)),
            .text("Changed the second line."), .text("checked"),
        ])
        workspace.agent.choiceClientFactory = { _, _ in client }
        let choice = IDEAIModelChoice(provider: .anthropic, model: "claude-sonnet-5-5", reasoningEffort: "high")
        workspace.agent.newChatChoice = choice
        workspace.agent.selected.modelChoice = choice
        workspace.showAIMode(tab: .code)
        workspace.agent.draft = "Change the second line of A.txt"
        workspace.agent.send()
        for _ in 0..<500 where workspace.agent.isRunning || !workspace.agent.entries.contains(where: { $0.kind == .changes }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(IDEAIChangedFiles.summarize(workspace.agent.entries).map(\.path), ["A.txt"])

        workspace.showsAIInspector = true
        for tab in IDEAIInspectorTab.allCases {
            workspace.aiInspectorTab = tab
            try await render("inspector-\(tab.rawValue)")
            if tab == .changes {
                // The tab works the diff out itself once it shows (render waits for it).
                XCTAssertEqual(workspace.aiChanges.results["A.txt"]?.diff?.added, 1)
                XCTAssertEqual(workspace.aiChanges.results["A.txt"]?.diff?.removed, 1)
            }
        }
        XCTAssertNotNil(workspace.aiBrowser, "showing the Browser tab made its page")
        XCTAssertEqual(workspace.aiBrowser?.hasStarted, false, "and nothing was loaded")
    }

    /// The Browser tab with notes on the page and select mode on.
    func testTheBrowserTabWithNotes() async throws {
        workspace.showAIMode(tab: .code)
        workspace.showsAIInspector = true
        workspace.aiInspectorTab = .browser
        let model = try XCTUnwrap(workspace.ensureAIBrowser())
        await model.load(
            html: "<!doctype html><title>Dashboard</title><body style='font:14px sans-serif'><h1>Dashboard</h1><button id='save'>Save</button></body>",
            baseURL: URL(string: "http://localhost:3000/dashboard")!)
        func element(_ selector: String, _ text: String) -> IDEAIElementInfo {
            IDEAIElementInfo(
                selector: selector, tag: "button", id: nil, classes: ["btn", "primary"], role: "button", label: text, text: text,
                html: "<button>", rect: .init(x: 0, y: 0, w: 10, h: 10), styles: [:], ancestors: [], redactions: 0, component: nil)
        }
        let url = try XCTUnwrap(model.page.url)
        model.annotations.add(note: "Make this the primary action and right-align it", pageURL: url, pageTitle: "Dashboard", element: element("#save", "Save"))
        let second = model.annotations.add(note: "Too close to the heading", pageURL: url, pageTitle: "Dashboard", element: element("h1", "Dashboard"))
        model.annotations.add(note: "", pageURL: url, pageTitle: "Dashboard", element: element("#gone", "Delete account"))
        model.annotations.markSent([try XCTUnwrap(second?.id)])
        model.isPicking = true
        try await render("inspector-browser-notes")
        model.isPicking = false
        model.teardown()
    }

    /// The Browser tab while the agent drives it, and the composer chip for the notes that go with the next message.
    func testTheBrowserTabWhileTheAgentActsAndTheNotesChip() async throws {
        let project = base.appendingPathComponent("MyProject")
        workspace.openProjectFolder(project)
        workspace.agent.settings.acceptDisclosure(for: .anthropic)
        let choice = IDEAIModelChoice(provider: .anthropic, model: "claude-sonnet-5-5", reasoningEffort: "high")
        workspace.agent.newChatChoice = choice
        workspace.agent.selected.modelChoice = choice
        workspace.showAIMode(tab: .code)
        workspace.showsAIInspector = true
        workspace.aiInspectorTab = .browser
        let model = try XCTUnwrap(workspace.ensureAIBrowser())
        await model.load(
            html: "<!doctype html><title>Form</title><body style='font:14px sans-serif'><h1>Settings</h1><button>Save</button></body>",
            baseURL: URL(string: "http://localhost:3000/settings")!)
        let element = IDEAIElementInfo(
            selector: "button", tag: "button", id: nil, classes: ["btn"], role: "button", label: "Save", text: "Save",
            html: "<button>", rect: .init(x: 0, y: 0, w: 10, h: 10), styles: [:], ancestors: [], redactions: 0, component: nil)
        let url = try XCTUnwrap(model.page.url)
        model.annotations.add(note: "Make Save the primary action", pageURL: url, pageTitle: "Form", element: element)
        model.annotations.add(note: "Heading is too small", pageURL: url, pageTitle: "Form", element: element)
        model.agentActivity = "Clicking"
        try await render("inspector-browser-agent-acting")
        model.agentActivity = nil
        model.teardown()
    }

    func testTheModelsSheet() async throws {
        let settings = IDEAgentSettings(
            defaults: UserDefaults(suiteName: "snap.sheet.\(UUID())")!, keyStore: IDEAgentMemoryKeyStore(), transport: SheetTransport())
        settings.saveAPIKey("sk-ant-test", for: .anthropic)
        let view = IDEAIModelsSheet(settings: settings)
            .environment(workspace)
            .preferredColorScheme(IDEAppearance.preferredColorScheme)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 560)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        for _ in 0..<50 where settings.ollamaModels.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
        try? await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(settings.ollamaModels.map(\.name), ["llama3.2:1b", "qwen3:8b"])
        guard let directory = ProcessInfo.processInfo.environment["AI_MODE_PNG_DIR"], let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("models-sheet.png"))
    }
}
