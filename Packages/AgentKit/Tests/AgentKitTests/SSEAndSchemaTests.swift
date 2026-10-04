import Foundation
import Testing
@testable import AgentKit

@Suite struct SSELineParserTests {
    let parser = SSELineParser()

    @Test func dataLinesCarryTheirPayload() {
        #expect(parser.parse(line: #"data: {"a":1}"#) == .data(#"{"a":1}"#))
        #expect(parser.parse(line: #"data:{"a":1}"#) == .data(#"{"a":1}"#))
    }

    @Test func doneEndsTheStream() {
        #expect(parser.parse(line: "data: [DONE]") == .done)
    }

    @Test func keepAlivesAndOtherFieldsAreSkipped() {
        #expect(parser.parse(line: ": keep-alive") == nil)
        #expect(parser.parse(line: "event: response.created") == nil)
        #expect(parser.parse(line: "id: 3") == nil)
        #expect(parser.parse(line: "") == nil)
        #expect(parser.parse(line: "data:") == nil)
    }
}

@Suite struct ToolDefinitionTests {
    let tool = ToolDefinition(
        name: "read_file", description: "Read a file.",
        parameters: [
            ToolParameter("path", .string, "Project-relative path."),
            ToolParameter("offset", .integer, "First line.", optional: true),
            ToolParameter("mode", .enumeration(["text", "hex"]), "Mode.", optional: true),
        ])

    @Test func strictSchemaRequiresEveryPropertyAndNullsTheOptionalOnes() {
        let schema = tool.schema(strict: true)
        #expect(schema["additionalProperties"] == false)
        #expect(schema["required"] == ["path", "offset", "mode"])
        #expect(schema["properties"]?["path"]?["type"] == "string")
        #expect(schema["properties"]?["offset"]?["type"] == ["integer", "null"])
        #expect(schema["properties"]?["mode"]?["enum"] == ["text", "hex", .null])
    }

    @Test func plainSchemaListsOnlyRequiredPropertiesAndKeepsTypesPlain() {
        let schema = tool.schema(strict: false)
        #expect(schema["additionalProperties"] == nil)
        #expect(schema["required"] == ["path"])
        #expect(schema["properties"]?["offset"]?["type"] == "integer")
    }

    @Test func arrayParametersDescribeTheirItems() {
        let schema = ToolDefinition(
            name: "t", description: "d", parameters: [ToolParameter("xs", .array(of: .string), "xs")]
        ).schema(strict: true)
        #expect(schema["properties"]?["xs"]?["items"]?["type"] == "string")
    }
}

@Suite struct JSONValueTests {
    @Test func roundTripsAndSortsKeys() throws {
        let value: JSONValue = ["b": 1, "a": ["x", true, .null], "c": .double(1.5)]
        #expect(try value.serialized() == #"{"a":["x",true,null],"b":1,"c":1.5}"#)
        #expect(try JSONValue(parsing: value.serialized()) == value)
    }
}

@Suite struct RetryPolicyTests {
    @Test func retriesTransientErrorsWithBackoffAndStopsAtTheLimit() {
        let policy = RetryPolicy(maxRetries: 2, baseDelay: 1, maxDelay: 30, jitter: false)
        #expect(policy.delay(for: LLMError.server(status: 503, message: ""), attempt: 0) == 1)
        #expect(policy.delay(for: LLMError.connectionLost(""), attempt: 1) == 2)
        #expect(policy.delay(for: LLMError.connectionLost(""), attempt: 2) == nil)
        #expect(policy.delay(for: URLError(.networkConnectionLost), attempt: 0) == 1)
    }

    @Test func honorsRetryAfterButCapsIt() {
        let policy = RetryPolicy(maxRetries: 3, baseDelay: 1, maxDelay: 30, jitter: false)
        #expect(policy.delay(for: LLMError.rateLimited(retryAfter: 10), attempt: 0) == 10)
        #expect(policy.delay(for: LLMError.rateLimited(retryAfter: 600), attempt: 0) == 30)
    }

    @Test func finalErrorsAreNotRetried() {
        let policy = RetryPolicy.default
        #expect(policy.delay(for: LLMError.unauthorized, attempt: 0) == nil)
        #expect(policy.delay(for: LLMError.contextLengthExceeded, attempt: 0) == nil)
        #expect(policy.delay(for: LLMError.badRequest(status: 400, message: ""), attempt: 0) == nil)
        #expect(policy.delay(for: CancellationError(), attempt: 0) == nil)
    }
}

@Suite struct HTTPErrorClassifierTests {
    private func classify(_ status: Int, _ body: String, _ retryAfter: TimeInterval? = nil) -> LLMError {
        HTTPErrorClassifier.classify(status: status, body: body, retryAfter: retryAfter)
    }

    @Test func classifiesByStatusAndBody() {
        #expect(classify(401, "{}") == .unauthorized)
        #expect(classify(429, #"{"error":{"message":"slow down"}}"#, 7) == .rateLimited(retryAfter: 7))
        #expect(classify(503, "overloaded") == .server(status: 503, message: "overloaded"))
        #expect(classify(400, #"{"error":{"code":"context_length_exceeded","message":"too long"}}"#) == .contextLengthExceeded)
        #expect(classify(404, #"{"error":{"message":"no such model"}}"#) == .badRequest(status: 404, message: "no such model"))
    }

    @Test func aSpentQuotaIsNotRetryable() {
        let error = classify(429, #"{"error":{"code":"insufficient_quota","message":"You exceeded your quota."}}"#)
        #expect(error == .api(message: "You exceeded your quota.", code: "insufficient_quota"))
    }

    @Test func parsesRetryAfterSeconds() {
        #expect(HTTPErrorClassifier.retryAfter(from: ["retry-after": " 12 "]) == 12)
        #expect(HTTPErrorClassifier.retryAfter(from: ["retry-after": "Wed, 21 Oct 2026 07:28:00 GMT"]) == nil)
        #expect(HTTPErrorClassifier.retryAfter(from: [:]) == nil)
    }
}
