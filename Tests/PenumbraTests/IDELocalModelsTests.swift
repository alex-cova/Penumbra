import AgentKit
import AgentKitMLX
import Foundation
import LocalModelStore
import XCTest
@testable import Umbra

/// Answers the Hugging Face API and file downloads from memory.
final class StubHubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: (status: Int, data: Data)] = [:]
    private static let lock = NSLock()

    static func serve(_ routes: [String: (status: Int, data: Data)]) { lock.withLock { self.routes = routes } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply = Self.lock.withLock { Self.routes[request.url?.path ?? ""] } ?? (404, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: ["Content-Length": "\(reply.data.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private let toolTemplate = #"{"chat_template":"{%- if tools %}# Tools{% endif %}{{ messages }}"}"#
private let plainTemplate = #"{"chat_template":"{% for m in messages %}{{ m.content }}{% endfor %}"}"#

@MainActor
final class IDELocalModelsStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("umbra-models-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore() -> IDELocalModelsStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubHubProtocol.self]
        return IDELocalModelsStore(rootURL: root, session: URLSession(configuration: configuration), runtime: LocalModelRuntime())
    }

    @discardableResult
    private func install(_ id: String, template: String = toolTemplate, config: String = #"{"model_type":"qwen2","max_position_embeddings":32768}"#) throws -> URL {
        let paths = LocalModelPaths(root: root)
        try paths.createDirectories()
        let directory = try paths.directory(for: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try template.write(to: directory.appendingPathComponent("tokenizer_config.json"), atomically: true, encoding: .utf8)
        try config.write(to: directory.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try LocalModelCatalog.writeManifest(
            LocalModelManifest(repositoryID: id, revision: "r", downloadedAt: .now, totalBytes: 1_000_000), into: directory)
        return directory
    }

    func testInstalledModelsAreListedAndInspected() throws {
        try install("acme/tools-4bit")
        try install("acme/plain-4bit", template: plainTemplate)
        let store = makeStore()
        store.prepareIfNeeded()
        XCTAssertEqual(Set(store.installed.map(\.id)), ["acme/tools-4bit", "acme/plain-4bit"])
        let tools = try XCTUnwrap(store.installed.first { $0.id == "acme/tools-4bit" })
        XCTAssertEqual(store.info(for: tools), MLXModelInfo(modelType: "qwen2", contextLength: 32_768, hasChatTemplate: true, supportsTools: true))
        let plain = try XCTUnwrap(store.installed.first { $0.id == "acme/plain-4bit" })
        XCTAssertFalse(store.info(for: plain).supportsTools)
    }

    func testDeletingRemovesTheFolderAndTheEntry() throws {
        let directory = try install("acme/gone-4bit")
        let store = makeStore()
        store.prepareIfNeeded()
        store.delete(try XCTUnwrap(store.installed.first))
        XCTAssertTrue(store.installed.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testSearchListsResultsAndSurfacesAFailure() async throws {
        StubHubProtocol.serve([
            "/api/models": (200, Data(#"[{"id":"acme/qwen-4bit","downloads":1200,"likes":3,"tags":["mlx","4-bit"],"pipeline_tag":"text-generation","gated":false},{"id":"acme/embedder","pipeline_tag":"feature-extraction"}]"#.utf8))
        ])
        let store = makeStore()
        store.query = "qwen"
        await store.search()
        XCTAssertNil(store.searchError)
        XCTAssertEqual(store.results.map(\.id), ["acme/qwen-4bit"], "only text-generation models can be loaded")
        XCTAssertEqual(store.results.first?.quantization, "4-bit")

        StubHubProtocol.serve([:])
        await store.search()
        XCTAssertTrue(store.results.isEmpty)
        XCTAssertNotNil(store.searchError)
    }

    func testDetailsReportTheDownloadSizeAndWhetherTheTemplateTakesTools() async throws {
        let weights = 3_000
        StubHubProtocol.serve([
            "/api/models/acme/qwen-4bit": (200, Data(#"{"id":"acme/qwen-4bit","sha":"s","gated":false,"siblings":[{"rfilename":"model.safetensors","size":\#(weights)},{"rfilename":"config.json","size":100},{"rfilename":"README.md","size":9999}]}"#.utf8)),
            "/acme/qwen-4bit/resolve/main/tokenizer_config.json": (200, Data(toolTemplate.utf8)),
            "/api/models/acme/plain-4bit": (200, Data(#"{"id":"acme/plain-4bit","siblings":[{"rfilename":"model.safetensors","size":10}]}"#.utf8)),
            "/acme/plain-4bit/resolve/main/tokenizer_config.json": (200, Data(plainTemplate.utf8)),
        ])
        let store = makeStore()
        await store.loadDetails(for: "acme/qwen-4bit")
        await store.loadDetails(for: "acme/plain-4bit")
        XCTAssertEqual(store.details["acme/qwen-4bit"]?.sizeBytes, Int64(weights + 100), "only what MLX loads counts, not the README")
        XCTAssertEqual(store.details["acme/qwen-4bit"]?.supportsTools, true)
        XCTAssertEqual(store.details["acme/plain-4bit"]?.supportsTools, false)
    }

    func testCancellingWithNothingRunningIsHarmless() throws {
        let store = makeStore()
        store.prepareIfNeeded()
        XCTAssertNil(store.download)
        XCTAssertTrue(store.canStartDownload)
        store.cancelDownload()
        store.pauseDownload()
        XCTAssertNil(store.download)
    }

    func testAPausedDownloadIsRestoredAfterARelaunch() throws {
        let paths = LocalModelPaths(root: root)
        try paths.createDirectories()
        let staging = paths.newStagingDirectory()
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try LocalModelDownloadCheckpoint(
            repositoryID: "acme/big-4bit", revision: "r", totalBytes: 1_000, completedBytes: 400, completedFiles: ["config.json"],
            currentFile: "model.safetensors", resumeData: nil, pausedAt: .now).write(into: staging)

        let store = makeStore()
        store.prepareIfNeeded()
        let download = try XCTUnwrap(store.download)
        XCTAssertEqual(download.id, "acme/big-4bit")
        XCTAssertTrue(download.isPaused)
        XCTAssertEqual(download.progress.fractionCompleted, 0.4)
        XCTAssertFalse(store.canStartDownload, "one download at a time, paused or not")

        store.cancelDownload()
        XCTAssertNil(store.download)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path), "cancelling a paused download discards its files")
    }

    func testLeftoversFromACrashedDownloadAreCleanedUp() throws {
        let paths = LocalModelPaths(root: root)
        try paths.createDirectories()
        let leftover = paths.newStagingDirectory()
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 10).write(to: leftover.appendingPathComponent("model.safetensors"))
        let store = makeStore()
        store.prepareIfNeeded()
        XCTAssertNil(store.download)
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
    }
}

@MainActor
final class IDEAgentMLXSettingsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("umbra-mlx-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func model(_ id: String, template: String) throws -> InstalledLocalModel {
        let directory = root.appendingPathComponent(LocalModelPaths.directoryName(for: id))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try template.write(to: directory.appendingPathComponent("tokenizer_config.json"), atomically: true, encoding: .utf8)
        try #"{"max_position_embeddings":8192}"#.write(to: directory.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        return InstalledLocalModel(
            manifest: LocalModelManifest(repositoryID: id, revision: "r", downloadedAt: .now, totalBytes: 1), directory: directory)
    }

    private func makeSettings(installed: [InstalledLocalModel]) -> IDEAgentSettings {
        IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.agent.tests.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore(),
            installedModels: { installed })
    }

    func testTheOnDeviceProviderIsLocalNeedsNoKeyAndNoConsent() throws {
        let settings = makeSettings(installed: [])
        settings.provider = .mlx
        XCTAssertTrue(settings.isLocalEndpoint)
        XCTAssertTrue(settings.hasAcceptedDisclosure, "nothing leaves the Mac")
        XCTAssertFalse(settings.requiresAPIKey)
        XCTAssertEqual(settings.endpointHost, "this Mac")
        XCTAssertEqual(settings.reasoningEffort, "off")
        XCTAssertNil(settings.endpointURL)
    }

    func testTheHintAsksForAModelThenForAnInstalledOne() throws {
        let settings = makeSettings(installed: [try model("acme/tools-4bit", template: toolTemplate)])
        settings.provider = .mlx
        guard MLXAvailability.currentStatus() == .available else { throw XCTSkip("MLX is not available in this test process") }
        XCTAssertTrue(settings.setupHint?.contains("Download a model") == true)
        settings.model = "acme/missing"
        XCTAssertTrue(settings.setupHint?.contains("is not downloaded") == true)
        settings.model = "acme/tools-4bit"
        XCTAssertNil(settings.setupHint)
    }

    func testAnInstalledToolModelBuildsAnMLXClientAndTheContextIsCapped() throws {
        guard MLXAvailability.currentStatus() == .available else { throw XCTSkip("MLX is not available in this test process") }
        let settings = makeSettings(installed: [try model("acme/tools-4bit", template: toolTemplate)])
        settings.provider = .mlx
        settings.model = "acme/tools-4bit"
        XCTAssertTrue(try settings.makeClient() is MLXLLMClient)
        settings.localContextLength = 131_072
        XCTAssertEqual(settings.effectiveContextLength, 8_192, "the model's own maximum limits the cap")
    }

    func testAModelWhoseTemplateIgnoresToolsIsRefusedAndAMissingOneIsReported() throws {
        guard MLXAvailability.currentStatus() == .available else { throw XCTSkip("MLX is not available in this test process") }
        let settings = makeSettings(installed: [try model("acme/plain-4bit", template: plainTemplate)])
        settings.provider = .mlx
        settings.model = "acme/plain-4bit"
        XCTAssertThrowsError(try settings.makeClient()) {
            XCTAssertEqual($0 as? IDEAgentSettings.ConfigurationError, .modelCannotUseTools("acme/plain-4bit"))
        }
        settings.model = "acme/gone"
        XCTAssertThrowsError(try settings.makeClient()) {
            XCTAssertEqual($0 as? IDEAgentSettings.ConfigurationError, .modelNotInstalled("acme/gone"))
        }
        settings.model = ""
        XCTAssertThrowsError(try settings.makeClient()) {
            XCTAssertEqual($0 as? IDEAgentSettings.ConfigurationError, .missingModel)
        }
    }

    func testSwitchingProvidersKeepsTheOnDeviceChoice() throws {
        let settings = makeSettings(installed: [])
        settings.provider = .mlx
        settings.model = "acme/tools-4bit"
        settings.provider = .ollama
        XCTAssertEqual(settings.model, "")
        settings.provider = .mlx
        XCTAssertEqual(settings.model, "acme/tools-4bit")
    }
}
