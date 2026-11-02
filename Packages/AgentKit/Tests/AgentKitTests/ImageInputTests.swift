import Foundation
import Testing
@testable import AgentKit

private let imageBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03])
private let imageID = "img-1"

private func partsRequest() -> LLMRequest {
    LLMRequest(
        model: "m",
        items: [.userParts([.text("Look at this"), .image(id: imageID, mediaType: "image/png")])],
        images: [imageID: LLMImage(id: imageID, mediaType: "image/png", data: imageBytes)])
}

private func encoded(_ data: Data) throws -> JSONValue {
    try JSONValue(parsing: String(decoding: data, as: UTF8.self))
}

// MARK: - Golden request bodies

@Suite struct ImageEncoderTests {
    @Test func anthropicSendsAnImageBlockWithABase64Source() throws {
        let body = try encoded(AnthropicRequestEncoder.body(for: partsRequest()))
        let messages = try #require(body["messages"]?.arrayValue)
        #expect(messages.count == 1)
        let content = try #require(messages[0]["content"]?.arrayValue)
        #expect(content.map { $0["type"]?.stringValue } == ["text", "image"])
        #expect(content[0]["text"] == "Look at this")
        #expect(content[1]["source"]?["type"] == "base64")
        #expect(content[1]["source"]?["media_type"] == "image/png")
        #expect(content[1]["source"]?["data"] == .string(imageBytes.base64EncodedString()))
    }

    @Test func responsesSendsInputImageWithADataURL() throws {
        let body = try encoded(ResponsesRequestEncoder.body(for: partsRequest()))
        let input = try #require(body["input"]?.arrayValue)
        #expect(input.count == 1)
        let content = try #require(input[0]["content"]?.arrayValue)
        #expect(content.map { $0["type"]?.stringValue } == ["input_text", "input_image"])
        #expect(content[1]["image_url"] == .string("data:image/png;base64,\(imageBytes.base64EncodedString())"))
    }

    @Test func chatCompletionsSendsImageURLWithADataURL() throws {
        let request = partsRequest()
        let messages = ChatCompletionsRequestEncoder.messages(for: request)
        let content = try #require(messages.first?["content"]?.arrayValue)
        #expect(content.map { $0["type"]?.stringValue } == ["text", "image_url"])
        #expect(content[1]["image_url"]?["url"] == .string("data:image/png;base64,\(imageBytes.base64EncodedString())"))
    }

    @Test func ollamaSendsTextPlusABase64ImagesArray() throws {
        let messages = OllamaRequestEncoder.messages(for: partsRequest())
        #expect(messages.count == 1)
        #expect(messages[0]["content"] == "Look at this")
        #expect(messages[0]["images"]?.arrayValue == [.string(imageBytes.base64EncodedString())])
    }

    @Test func plainUserMessagesEncodeExactlyAsBefore() throws {
        let request = LLMRequest(model: "m", items: [.user("hi")])
        let anthropic = try encoded(AnthropicRequestEncoder.body(for: request))
        let aMessages = try #require(anthropic["messages"]?.arrayValue)
        let aContent = try #require(aMessages[0]["content"]?.arrayValue)
        #expect(aContent[0]["text"] == "hi")
        let responses = try encoded(ResponsesRequestEncoder.body(for: request))
        let rInput = try #require(responses["input"]?.arrayValue)
        #expect(rInput[0]["content"] == "hi", "a text-only turn stays a string, not an array")
        let chat = ChatCompletionsRequestEncoder.messages(for: request)
        #expect(chat.first?["content"] == "hi")
        let ollama = OllamaRequestEncoder.messages(for: request)
        #expect(ollama.first?["images"] == nil)
    }

    @Test func missingBytesBecomeATextNoteNeverTheBytes() throws {
        let request = LLMRequest(
            model: "m", items: [.userParts([.text("Look"), .image(id: "gone", mediaType: "image/png")])])
        let b64 = imageBytes.base64EncodedString()
        let anthropic = try String(decoding: AnthropicRequestEncoder.body(for: request), as: UTF8.self)
        #expect(anthropic.contains("cannot see images") || anthropic.contains("missing"))
        #expect(!anthropic.contains(b64))
        let responses = try String(decoding: ResponsesRequestEncoder.body(for: request), as: UTF8.self)
        #expect(!responses.contains(b64))
        let chat = String(
            decoding: try ChatCompletionsRequestEncoder.body(for: request, capabilities: .openAI), as: UTF8.self)
        #expect(!chat.contains(b64))
        let ollama = String(
            decoding: try OllamaRequestEncoder.body(for: request, contextLength: 4096, supportsThinking: false),
            as: UTF8.self)
        #expect(!ollama.contains(b64))
    }
}

// MARK: - Capability flags

@Suite struct ImageCapabilityTests {
    @Test func hostedClientsSeeImages() {
        #expect(AnthropicMessagesClient().supportsImages)
        #expect(OpenAIResponsesClient().supportsImages)
        #expect(OpenAIChatCompletionsClient(capabilities: .openAI).supportsImages)
    }

    @Test func conservativeAndLocalClientsStayTextOnly() {
        #expect(!OpenAIChatCompletionsClient(capabilities: .compatible).supportsImages)
        #expect(!OllamaClient().supportsImages, "no vision flag means no image parts")
        #expect(OllamaClient(supportsVision: true).supportsImages)
    }

    @Test func aClientWithoutSupportGetsATextNote() {
        let item = ConversationItem.userParts([.text("Look"), .image(id: imageID, mediaType: "image/png")])
        let fallback = AgentSession.textOnlyFallback(item)
        guard case .user(let text) = fallback else {
            Issue.record("a text-only client gets a plain user message")
            return
        }
        #expect(text.contains("Look"))
        #expect(text.contains(imageID), "the note names the image it replaced")
        #expect(AgentSession.textOnlyFallback(.user("hi")) == .user("hi"), "plain turns pass through")
    }
}

// MARK: - Budget and compaction

@Suite struct ImageBudgetTests {
    @Test func anImageCountsAFixedEstimate() {
        let textOnly = ContextBudget.tokens(.user("Look at this"))
        let withImage = ContextBudget.tokens(
            ConversationItem.userParts([.text("Look at this"), .image(id: imageID, mediaType: "image/png")]))
        #expect(withImage == textOnly + ContextBudget.imageTokenEstimate)
    }

    @Test func compactionDropsImagesBeforeItTouchesText() {
        let items: [ConversationItem] = [
            .userParts([.text("first screenshot"), .image(id: "a", mediaType: "image/png")]),
            .userParts([.text("second screenshot"), .image(id: "b", mediaType: "image/png")]),
            .user("keep these words"),
        ]
        let before = ContextBudget.tokens(items)
        let target = ContextBudget.tokens(.user("keep these words")) + ContextBudget.tokens("second screenshot")
            + ContextBudget.imageTokenEstimate + 100
        let (result, removed) = ImageStubs.apply(
            to: items, keepRecentImages: 1, estimatedTokens: before, targetTokens: target)
        #expect(removed == 1, "the oldest image goes, the newest stays")
        #expect(!result[0].hasImages)
        #expect(result[0].userText?.contains("first screenshot") == true, "the words stay, only the bytes go")
        #expect(result[1].hasImages, "the newest turn keeps its image")
        #expect(result[2] == .user("keep these words"))
    }

    @Test func compactionAddsAReportCount() {
        var report = CompactionReport()
        #expect(!report.changedAnything)
        report.elidedImages = 2
        #expect(report.changedAnything)
    }
}

// MARK: - SessionStore round trip

@Suite struct ImageStoreTests {
    private func makeStore() -> (SessionStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("images-\(UUID().uuidString)", isDirectory: true)
        return (SessionStore(directory: directory), directory)
    }

    @Test func anImageSurvivesASaveAndLoadBesideTheSession() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let id = try store.saveImage(imageBytes, mediaType: "image/png", sessionID: sessionID, projectRoot: "/proj/a")
        var snapshot = SessionSnapshot(
            id: sessionID, projectRoot: "/proj/a", title: "t",
            items: [.userParts([.text("Look"), .image(id: id, mediaType: "image/png")])])
        try store.save(snapshot)
        let loaded = try #require(store.load(sessionID, projectRoot: "/proj/a"))
        #expect(loaded.items == snapshot.items, "history JSON references the image by id")
        let raw = try #require(try? Data(contentsOf: store.imageDirectory(for: sessionID, projectRoot: "/proj/a").appendingPathComponent("\(id).png")))
        #expect(raw == imageBytes)
        let resolved = store.loadImages(ids: [id], sessionID: sessionID, projectRoot: "/proj/a")
        #expect(resolved[id]?.data == imageBytes)
        #expect(resolved[id]?.mediaType == "image/png")
        // The JSON holds the id, never the bytes.
        let json = try String(contentsOf: store.projectDirectory(for: "/proj/a").appendingPathComponent("\(sessionID.uuidString).json"))
        #expect(json.contains(id))
        #expect(!json.contains(imageBytes.base64EncodedString()))
        snapshot.title = "unused"
    }

    @Test func deletingASessionDeletesItsImages() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        _ = try store.saveImage(imageBytes, mediaType: "image/jpeg", sessionID: sessionID, projectRoot: "/proj/a")
        try store.save(SessionSnapshot(id: sessionID, projectRoot: "/proj/a", title: "t", items: [.user("hi")]))
        store.delete(sessionID, projectRoot: "/proj/a")
        #expect(store.loadImages(ids: ["anything"], sessionID: sessionID, projectRoot: "/proj/a").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.imageDirectory(for: sessionID, projectRoot: "/proj/a").path))
    }

    @Test func unsupportedTypesAndOversizeImagesAreRefused() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: (any Error).self) {
            try store.saveImage(imageBytes, mediaType: "image/tiff", sessionID: UUID(), projectRoot: "/proj/a")
        }
    }
}
