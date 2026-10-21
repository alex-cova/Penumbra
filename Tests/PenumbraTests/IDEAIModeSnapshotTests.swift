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

    private func render(_ name: String, width: CGFloat = 1100, height: CGFloat = 720) throws {
        var sidebarWidth = 240.0
        let view = IDEAIModeView(sidebarWidth: Binding(get: { sidebarWidth }, set: { sidebarWidth = $0 }))
            .environment(workspace)
            .frame(width: width, height: height)
            .background(IDEAppearance.ColorToken.window)
            .preferredColorScheme(IDEAppearance.preferredColorScheme)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Let SwiftUI run its task and onAppear work.
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.width, 0)
        guard let directory = ProcessInfo.processInfo.environment["AI_MODE_PNG_DIR"], let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    func testChatEmptyAndWithAConversation() async throws {
        workspace.showAIMode(tab: .chat)
        try render("chat-empty")

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
        try render("chat-conversation")
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
        try render("code-conversation")
    }

    func testCodeWithNoProjectAndWithAProject() throws {
        workspace.showAIMode(tab: .code)
        try render("code-no-project")

        workspace.openProjectFolder(base.appendingPathComponent("MyProject"))
        try render("code-project-empty")
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
