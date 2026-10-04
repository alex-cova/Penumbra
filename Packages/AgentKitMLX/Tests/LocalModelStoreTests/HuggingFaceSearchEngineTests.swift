import Foundation
import Testing
@testable import LocalModelStore

struct HuggingFaceSearchEngineTests {
    private static let listJSON = """
    [
      {"_id":"1","id":"mlx-community/Qwen3-4B-4bit","downloads":19750,"likes":16,
       "tags":["mlx","safetensors","qwen3","text-generation","4-bit"],"pipeline_tag":"text-generation",
       "gated":false,"private":false,"safetensors":{"total":4022468096}},
      {"id":"meta-llama/Llama-3.2-1B","downloads":5,"likes":1,"tags":["mlx","8bit"],
       "pipeline_tag":"text-generation","gated":"manual"},
      {"id":"lmstudio-community/Some-VLM-4bit","downloads":9,"likes":2,"tags":["mlx"],
       "pipeline_tag":"image-text-to-text","gated":false},
      {"id":"acme/bare"}
    ]
    """

    // MARK: - Requests

    @Test func searchRequestNarrowsToMLXTextGenerationServerSide() throws {
        let url = try #require(HuggingFaceSearchEngine.searchRequest(query: "qwen").url)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.filter { $0.name == "filter" }.compactMap(\.value) == ["mlx", "text-generation"])
        #expect(items.first { $0.name == "search" }?.value == "qwen")
        #expect(items.first { $0.name == "sort" }?.value == "downloads")
        #expect(url.path == "/api/models")
    }

    @Test func searchRequestOmitsSearchWhenQueryIsBlank() throws {
        let url = try #require(HuggingFaceSearchEngine.searchRequest(query: "   ").url)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(!items.contains { $0.name == "search" })
    }

    /// The list endpoint rejects `usedStorage` outright, which fails the whole request.
    @Test func searchRequestNeverAsksForFieldsTheListEndpointRejects() throws {
        let url = try #require(HuggingFaceSearchEngine.searchRequest(query: "x").url)
        let expanded = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            .filter { $0.name == "expand[]" }.compactMap(\.value)
        #expect(!expanded.isEmpty)
        #expect(!expanded.contains("usedStorage"))
        #expect(expanded.contains("safetensors"))
    }

    @Test func infoRequestAsksForBlobsSoFileSizesArePresent() throws {
        let url = try #require(HuggingFaceSearchEngine.infoRequest(id: "acme/tiny").url)
        #expect(url.path == "/api/models/acme/tiny")
        #expect(url.query == "blobs=true")
    }

    @Test func infoRequestSendsTheTokenOnlyWhenGiven() throws {
        #expect(try HuggingFaceSearchEngine.infoRequest(id: "acme/tiny").value(forHTTPHeaderField: "Authorization") == nil)
        #expect(try HuggingFaceSearchEngine.infoRequest(id: "acme/tiny", token: "").value(forHTTPHeaderField: "Authorization") == nil)
        #expect(try HuggingFaceSearchEngine.infoRequest(id: "acme/tiny", token: "hf_x").value(forHTTPHeaderField: "Authorization") == "Bearer hf_x")
    }

    @Test func infoRequestRejectsAnInvalidID() {
        #expect(throws: LocalModelError.invalidRepositoryID("../etc/passwd")) {
            try HuggingFaceSearchEngine.infoRequest(id: "../etc/passwd")
        }
    }

    // MARK: - Decoding

    @Test func decodeSearchDropsNonTextGenerationRepos() throws {
        let results = try HuggingFaceSearchEngine.decodeSearch(Data(Self.listJSON.utf8))
        #expect(!results.contains { $0.id == "lmstudio-community/Some-VLM-4bit" })
    }

    @Test func decodeSearchReadsFields() throws {
        let results = try HuggingFaceSearchEngine.decodeSearch(Data(Self.listJSON.utf8))
        let qwen = try #require(results.first { $0.id == "mlx-community/Qwen3-4B-4bit" })
        #expect(qwen.downloads == 19750)
        #expect(qwen.likes == 16)
        #expect(qwen.parameterCount == 4_022_468_096)
        #expect(qwen.quantization == "4-bit")
        #expect(!qwen.isGated)
    }

    @Test func gatedIsSurfacedWhetherTheHubSendsABoolOrAString() throws {
        let results = try HuggingFaceSearchEngine.decodeSearch(Data(Self.listJSON.utf8))
        let gatedByString = try #require(results.first { $0.id == "meta-llama/Llama-3.2-1B" })
        let openByBool = try #require(results.first { $0.id == "mlx-community/Qwen3-4B-4bit" })
        #expect(gatedByString.isGated)
        #expect(!openByBool.isGated)
    }

    /// A repo missing every optional field still decodes; it just lacks a pipeline tag, so the
    /// text-generation backstop drops it.
    @Test func sparseRowsDecodeButAreFilteredOut() throws {
        let rows = try JSONDecoder().decode([HFModelSummary].self, from: Data(Self.listJSON.utf8))
        let bare = try #require(rows.first { $0.id == "acme/bare" })
        #expect(bare.downloads == 0 && bare.tags.isEmpty && bare.pipelineTag == nil)
        #expect(try !HuggingFaceSearchEngine.decodeSearch(Data(Self.listJSON.utf8)).contains { $0.id == "acme/bare" })
    }

    @Test func quantizationRecognisesTheSpellingsTheHubUses() {
        #expect(HFModelSummary(id: "a/b", tags: ["8bit"]).quantization == "8bit")
        #expect(HFModelSummary(id: "a/b", tags: ["4-bit"]).quantization == "4-bit")
        #expect(HFModelSummary(id: "a/b", tags: ["mlx", "bf16"]).quantization == nil)
    }

    @Test func decodeSearchThrowsOnMalformedJSON() {
        #expect(throws: LocalModelError.malformedResponse) { try HuggingFaceSearchEngine.decodeSearch(Data("not json".utf8)) }
    }

    /// The Hub answers an invalid query with a JSON object, not an array.
    @Test func decodeSearchThrowsWhenTheHubReturnsAnErrorObject() {
        #expect(throws: LocalModelError.malformedResponse) {
            try HuggingFaceSearchEngine.decodeSearch(Data(#"{"error":"Invalid option"}"#.utf8))
        }
    }

    @Test func decodeInfoReadsSiblingsAndSizes() throws {
        let json = """
        {"id":"acme/tiny","sha":"abc123","gated":false,"usedStorage":2263022529,
         "siblings":[{"rfilename":"config.json","size":937},{"rfilename":"model.safetensors","size":2263022529},
                     {"rfilename":"README.md"}]}
        """
        let info = try HuggingFaceSearchEngine.decodeInfo(Data(json.utf8))
        #expect(info.sha == "abc123")
        #expect(info.usedStorage == 2_263_022_529)
        #expect(info.siblings.map(\.path) == ["config.json", "model.safetensors", "README.md"])
        #expect(info.siblings.last?.size == nil)
    }

    @Test func decodeInfoThrowsWithoutAnID() {
        #expect(throws: LocalModelError.malformedResponse) { try HuggingFaceSearchEngine.decodeInfo(Data("{}".utf8)) }
    }
}
