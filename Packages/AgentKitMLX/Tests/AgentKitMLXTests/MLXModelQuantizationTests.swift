import Foundation
import LocalModelStore
import Testing
@testable import AgentKitMLX

@Suite struct MLXModelQuantizationTests {
    private func configDirectory(_ config: String, id: String = "acme/model") throws -> InstalledLocalModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbra-quant-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try config.write(to: directory.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        return InstalledLocalModel(
            manifest: LocalModelManifest(repositoryID: id, revision: "r", downloadedAt: .now, totalBytes: 1),
            directory: directory)
    }

    @Test func quantizationBitsComesFromTheTopLevelOrTextConfig() throws {
        let oneBit = try configDirectory(#"{"quantization":{"group_size":128,"bits":1}}"#)
        defer { try? FileManager.default.removeItem(at: oneBit.directory) }
        #expect(MLXModelInspector.quantizationBits(in: oneBit.directory) == 1)
        #expect(MLXModelInspector.inspect(directory: oneBit.directory).quantizationBits == 1)

        let nested = try configDirectory(#"{"text_config":{"quantization":{"group_size":64,"bits":4}}}"#)
        defer { try? FileManager.default.removeItem(at: nested.directory) }
        #expect(MLXModelInspector.quantizationBits(in: nested.directory) == 4)

        let full = try configDirectory(#"{"model_type":"qwen2"}"#)
        defer { try? FileManager.default.removeItem(at: full.directory) }
        #expect(MLXModelInspector.quantizationBits(in: full.directory) == nil)
    }

    @Test func onlyWhatMLXSupportsHasNoMessage() {
        for bits in [2, 3, 4, 5, 6, 8, nil] {
            #expect(
                MLXModelInspector.unsupportedQuantizationMessage(modelID: "acme/model", bits: bits) == nil,
                "bits: \(bits.map(String.init) ?? "nil")")
        }
        #expect(
            MLXModelInspector.unsupportedQuantizationMessage(modelID: "acme/model", bits: 1)?.contains("1 bit") == true)
    }

    @Test func loadingRefusesAQuantizationMLXCannotRun() async throws {
        let model = try configDirectory(#"{"quantization":{"group_size":128,"bits":1}}"#, id: "acme/onebit")
        defer { try? FileManager.default.removeItem(at: model.directory) }
        do {
            try await LocalModelRuntime().load(model)
            Issue.record("loading a 1-bit model must throw instead of crashing MLX")
        } catch {
            #expect(error as? LocalModelError == .unsupportedQuantization(modelID: "acme/onebit", bits: 1))
        }
    }
}
