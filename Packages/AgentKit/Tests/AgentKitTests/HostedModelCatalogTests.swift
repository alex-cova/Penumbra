import Foundation
import Testing
@testable import AgentKit

@Suite struct HostedModelCatalogTests {
    @Test func parsesTheOpenAIShapeAndDedupes() {
        let data = Data(#"{"object":"list","data":[{"id":"muse-spark-1.3"},{"id":"muse-spark-1.2"},{"id":"muse-spark-1.3"},{"id":""}]}"#.utf8)
        #expect(HostedModelCatalog.parse(data) == ["muse-spark-1.3", "muse-spark-1.2"])
    }

    @Test func parsesBareListsOfIdsOrObjects() {
        #expect(HostedModelCatalog.parse(Data(#"{"models":["a","b"]}"#.utf8)) == ["a", "b"])
        #expect(HostedModelCatalog.parse(Data(#"[{"id":"a"}]"#.utf8)) == ["a"])
        #expect(HostedModelCatalog.parse(Data("not json".utf8)) == [])
    }

    @Test func fetchesModelsWithTheBearerKey() async throws {
        let transport = RouteTransport { _ in
            (200, Data(#"{"data":[{"id":"muse-spark-1.3"},{"id":"muse-wonder-1.0"}]}"#.utf8))
        }
        let catalog = HostedModelCatalog(
            endpoint: LLMEndpoint(baseURL: LLMEndpoint.meta.baseURL, apiKey: "k-test"), transport: transport)
        #expect(try await catalog.models() == ["muse-spark-1.3", "muse-wonder-1.0"])
        let sent = try #require(transport.requests.first)
        #expect(sent.url?.absoluteString == "https://api.meta.ai/v1/models")
        #expect(sent.httpMethod == "GET")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer k-test")
    }

    @Test func aRejectedKeyIsUnauthorized() async throws {
        let transport = RouteTransport { _ in (401, Data(#"{"error":{"message":"bad key"}}"#.utf8)) }
        let catalog = HostedModelCatalog(
            endpoint: LLMEndpoint(baseURL: LLMEndpoint.meta.baseURL, apiKey: "bad"), transport: transport)
        await #expect(throws: LLMError.unauthorized) { _ = try await catalog.models() }
    }
}
