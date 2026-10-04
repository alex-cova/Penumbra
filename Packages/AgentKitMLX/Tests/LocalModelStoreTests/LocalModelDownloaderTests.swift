import Foundation
import Testing
@testable import LocalModelStore

/// A URLProtocol that answers the Hugging Face API and file downloads from memory.
final class StubHub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (status: Int, data: Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    private static let lock = NSLock()

    static func reset(_ handler: @escaping @Sendable (URLRequest) -> (status: Int, data: Data)) {
        lock.withLock { requests = []; self.handler = handler }
    }

    static var seen: [URLRequest] { lock.withLock { requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.requests.append(request) }
        let (status, data) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Length": "\(data.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct LocalModelDownloaderTests {
    private let endpoint = URL(string: "https://hub.test")!

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubHub.self]
        return URLSession(configuration: configuration)
    }

    private func makePaths() throws -> LocalModelPaths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("downloader-\(UUID().uuidString)")
        let paths = LocalModelPaths(root: root)
        try paths.createDirectories()
        return paths
    }

    /// Serves one repository: its listing at `/api/models/<id>` and each file at `/<id>/resolve/<sha>/<path>`.
    private func serve(
        id: String = "acme/tiny-4bit", sha: String = "abc123", gated: Bool = false,
        files: [String: Data], listedSizes: [String: Int64]? = nil
    ) {
        StubHub.reset { request in
            let path = request.url?.path ?? ""
            if path == "/api/models/\(id)" {
                let siblings = files.keys.sorted().map { name -> String in
                    let size = listedSizes?[name] ?? Int64(files[name]!.count)
                    return #"{"rfilename":"\#(name)","size":\#(size)}"#
                }.joined(separator: ",")
                let body = #"{"id":"\#(id)","sha":"\#(sha)","gated":\#(gated ? #""manual""# : "false"),"siblings":[\#(siblings)]}"#
                return (200, Data(body.utf8))
            }
            if path.hasPrefix("/\(id)/resolve/\(sha)/"), let data = files[String(path.dropFirst("/\(id)/resolve/\(sha)/".count))] {
                return (200, data)
            }
            return (404, Data())
        }
    }

    private func download(
        _ id: String = "acme/tiny-4bit", token: String? = nil, into paths: LocalModelPaths,
        control: LocalModelDownloadControl? = nil, progress: @escaping @Sendable (LocalModelDownloadProgress) -> Void = { _ in }
    ) async throws -> InstalledLocalModel {
        try await LocalModelDownloader(session: session(), endpoint: endpoint)
            .download(id: id, token: token, into: paths, control: control, progress: progress)
    }

    private var repository: [String: Data] {
        [
            "model.safetensors": Data(repeating: 7, count: 4_096),
            "config.json": Data(#"{"model_type":"llama"}"#.utf8),
            "tokenizer.json": Data("{}".utf8),
            "tokenizer_config.json": Data("{}".utf8),
            "README.md": Data("# not needed".utf8),
            "pytorch_model.bin": Data(repeating: 1, count: 100),
        ]
    }

    @Test func installsOnlyWhatMLXNeedsAndWritesTheManifestLast() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        serve(files: repository)
        let installed = try await download(into: paths)

        #expect(installed.id == "acme/tiny-4bit")
        #expect(installed.manifest.revision == "abc123")
        let folder = try paths.directory(for: "acme/tiny-4bit")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == ["config.json", "hextech-model.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json"])
        #expect(installed.manifest.totalBytes == 4_096 + 22 + 2 + 2)
        #expect(LocalModelCatalog(paths: paths).installed().map(\.id) == ["acme/tiny-4bit"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.stagingRoot.path).isEmpty, "no staging folder is left")
    }

    @Test func reportsProgressUpToTheWholeSize() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        serve(files: repository)
        let last = LockedBox<LocalModelDownloadProgress?>(nil)
        _ = try await download(into: paths, progress: { last.set($0) })
        let final = try #require(last.value)
        #expect(final.fractionCompleted == 1)
        #expect(final.bytesDownloaded == final.totalBytes && final.totalBytes > 0)
    }

    @Test func aListingThatTriesToEscapeTheModelFolderInstallsNothing() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        for evil in ["../escape.safetensors", "a/../../escape.json", "/etc/passwd.json", "sub/../../x.json"] {
            serve(files: ["model.safetensors": Data(repeating: 1, count: 8), evil: Data("x".utf8)])
            await #expect(throws: LocalModelError.self) { _ = try await download(into: paths) }
        }
        #expect(LocalModelCatalog(paths: paths).installed().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.stagingRoot.path).isEmpty, "a failed download cleans up after itself")
        #expect(!FileManager.default.fileExists(atPath: paths.root.deletingLastPathComponent().appendingPathComponent("escape.safetensors").path))
    }

    @Test func aFileShorterThanTheHubPromisedIsRefusedAndNothingIsInstalled() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        serve(files: ["model.safetensors": Data(repeating: 1, count: 10), "config.json": Data("{}".utf8)], listedSizes: ["model.safetensors": 9_999])
        await #expect(throws: LocalModelError.incompleteDownload(file: "model.safetensors", expected: 9_999, actual: 10)) {
            _ = try await download(into: paths)
        }
        #expect(LocalModelCatalog(paths: paths).installed().isEmpty)
    }

    @Test func aRepositoryWithoutWeightsIsRefusedBeforeAnythingIsDownloaded() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        serve(files: ["config.json": Data("{}".utf8), "pytorch_model.bin": Data(repeating: 1, count: 10)])
        await #expect(throws: LocalModelError.noModelFiles("acme/tiny-4bit")) { _ = try await download(into: paths) }
        #expect(StubHub.seen.allSatisfy { $0.url?.path.contains("/resolve/") == false }, "no file was fetched")
    }

    @Test func aGatedModelNeedsATokenAndTheTokenIsSent() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        serve(gated: true, files: ["model.safetensors": Data(repeating: 1, count: 8)])
        await #expect(throws: LocalModelError.gatedModel("acme/tiny-4bit")) { _ = try await download(into: paths) }

        _ = try await download(token: "hf_secret", into: paths)
        let authorized = StubHub.seen.filter { $0.value(forHTTPHeaderField: "Authorization") == "Bearer hf_secret" }
        #expect(authorized.count >= 2, "the token goes with the listing and with each file")
    }

    @Test func aMalformedRepositoryIDNeverReachesTheNetwork() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        serve(files: repository)
        for id in ["../etc", "no-slash", "a/b/c", "owner/..", "/abs/path", ""] {
            await #expect(throws: LocalModelError.self) { _ = try await download(id, into: paths) }
        }
        #expect(StubHub.seen.isEmpty)
    }

    @Test func cancellingLeavesNothingBehind() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        serve(files: repository)
        let control = LocalModelDownloadControl()
        control.cancel()
        await #expect(throws: CancellationError.self) { _ = try await download(into: paths, control: control) }
        #expect(LocalModelCatalog(paths: paths).installed().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.stagingRoot.path).isEmpty)
    }

    @Test func aSecondDownloadReplacesTheFirstAtomically() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        serve(sha: "v1", files: repository)
        _ = try await download(into: paths)
        serve(sha: "v2", files: repository)
        let second = try await download(into: paths)
        #expect(second.manifest.revision == "v2")
        #expect(LocalModelCatalog(paths: paths).installed().count == 1)
    }
}

final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    func set(_ value: Value) { lock.withLock { stored = value } }
    var value: Value { lock.withLock { stored } }
}
