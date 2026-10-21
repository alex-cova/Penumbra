import Foundation
import Testing
@testable import AgentKit

@Suite struct OllamaPullTests {
    private let lines = [
        #"{"status":"pulling manifest"}"#,
        #"{"status":"pulling aaa","digest":"sha256:aaa","total":1000,"completed":250}"#,
        #"{"status":"pulling aaa","digest":"sha256:aaa","total":1000,"completed":1000}"#,
        #"{"status":"pulling bbb","digest":"sha256:bbb","total":3000,"completed":0}"#,
        #"{"status":"pulling bbb","digest":"sha256:bbb","total":3000,"completed":1500}"#,
        #"{"status":"verifying sha256 digest"}"#,
        #"{"status":"success"}"#,
    ]

    private func collectProgress(_ stream: AsyncThrowingStream<OllamaPullProgress, Error>) async throws -> [OllamaPullProgress] {
        var all: [OllamaPullProgress] = []
        for try await progress in stream { all.append(progress) }
        return all
    }

    @Test func progressAddsUpTheLayersAndEndsWithSuccess() async throws {
        let transport = StubTransport([.response(status: 200, lines: lines)])
        let all = try await collectProgress(OllamaModelCatalog(transport: transport).pull(" qwen3:8b "))
        #expect(all.first?.status == "pulling manifest" && all.first?.fraction == nil)
        #expect(all[1].completedBytes == 250 && all[1].totalBytes == 1000)
        // The second layer announces its size, so the total grows.
        #expect(all[3].totalBytes == 4000 && all[3].completedBytes == 1000)
        #expect(all[4].fraction == 0.625)
        #expect(all.last?.isFinished == true && all.last?.status == "success")
        let sent = try #require(transport.requests.first)
        #expect(sent.url?.path == "/api/pull")
        let body = try JSONValue(parsing: String(decoding: sent.httpBody ?? Data(), as: UTF8.self))
        #expect(body["model"] == "qwen3:8b", "the name is trimmed")
        #expect(body["stream"] == true)
    }

    @Test func anErrorLineEndsThePullWithItsMessage() async throws {
        let transport = StubTransport([.response(status: 200, lines: [
            #"{"status":"pulling manifest"}"#, #"{"error":"pull model manifest: file does not exist"}"#,
        ])])
        await #expect(throws: LLMError.api(message: "pull model manifest: file does not exist", code: nil)) {
            _ = try await collectProgress(OllamaModelCatalog(transport: transport).pull("nope"))
        }
    }

    @Test func aStreamThatEndsBeforeSuccessIsNotADownload() async throws {
        let transport = StubTransport([.response(status: 200, lines: Array(lines.prefix(3)))])
        await #expect(throws: LLMError.connectionLost("The download stopped before it finished.")) {
            _ = try await collectProgress(OllamaModelCatalog(transport: transport).pull("qwen3:8b"))
        }
    }

    @Test func aBlankNameAndAMissingServerAreReportedWithoutARequest() async throws {
        let transport = StubTransport([])
        await #expect(throws: LLMError.badRequest(status: 400, message: "Enter a model name, such as qwen3:8b.")) {
            _ = try await collectProgress(OllamaModelCatalog(transport: transport).pull("   "))
        }
        #expect(transport.requests.isEmpty)

        let down = StubTransport([.failure(URLError(.cannotConnectToHost))])
        await #expect(throws: LLMError.unreachable("Ollama isn't running at localhost:11434.")) {
            _ = try await collectProgress(OllamaModelCatalog(transport: down).pull("qwen3:8b"))
        }
    }

    @Test func deleteSendsTheNameAndSurfacesAMissingModel() async throws {
        let transport = RouteTransport { _ -> (status: Int, data: Data) in (200, Data()) }
        try await OllamaModelCatalog(transport: transport).delete("qwen3:8b")
        let sent = try #require(transport.requests.first)
        #expect(sent.httpMethod == "DELETE" && sent.url?.path == "/api/delete")
        #expect(try JSONValue(parsing: String(decoding: sent.httpBody ?? Data(), as: UTF8.self))["model"] == "qwen3:8b")

        let missing = RouteTransport { _ -> (status: Int, data: Data) in (404, Data(#"{"error":"model 'x' not found"}"#.utf8)) }
        await #expect(throws: LLMError.badRequest(status: 404, message: "model 'x' not found")) {
            try await OllamaModelCatalog(transport: missing).delete("x")
        }
    }

    @Test func visionIsReadFromCapabilities() {
        let model = OllamaModel(
            name: "llava", parameterSize: nil, quantization: nil, sizeBytes: 0, capabilities: ["completion", "vision"], contextLength: nil)
        #expect(model.supportsVision && !model.supportsTools)
    }
}
