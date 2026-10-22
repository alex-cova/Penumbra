import Foundation
import Testing
@testable import AgentKit

@Suite struct ToolArgumentsTests {
    private func arguments(_ json: String) throws -> ToolArguments { try ToolArguments(json: json) }

    @Test func anIntegerWrittenAsAStringIsRead() throws {
        let args = try arguments(#"{"limit":"20","offset":" 5 ","exact":"3.0","real":7}"#)
        #expect(try args.optionalInt("limit") == 20)
        #expect(try args.optionalInt("offset") == 5)
        #expect(try args.optionalInt("exact") == 3)
        #expect(try args.optionalInt("real") == 7)
    }

    @Test func aBooleanWrittenAsAStringIsRead() throws {
        let args = try arguments(#"{"a":"true","b":"False","c":true}"#)
        #expect(try args.optionalBool("a") == true)
        #expect(try args.optionalBool("b") == false)
        #expect(try args.optionalBool("c") == true)
    }

    @Test func aListWrittenAsAJSONStringIsRead() throws {
        let args = try arguments(#"{"json":"[\"a\",\"b\"]","real":["x"],"one":"src/main.swift","mixed":"[1,2]"}"#)
        #expect(try args.optionalStringArray("json") == ["a", "b"])
        #expect(try args.optionalStringArray("real") == ["x"])
        // A lone string is not a list, and numbers are not strings: neither is guessed at.
        #expect(throws: ToolError.self) { try args.optionalStringArray("one") }
        #expect(throws: ToolError.self) { try args.optionalStringArray("mixed") }
    }

    @Test func anEmptyObjectOrNullMeansTheParameterWasSkipped() throws {
        let args = try arguments(#"{"limit":{},"flag":{},"path":{},"paths":{},"nothing":null}"#)
        #expect(try args.optionalInt("limit") == nil)
        #expect(try args.optionalBool("flag") == nil)
        #expect(try args.optionalString("path") == nil)
        #expect(try args.optionalStringArray("paths") == nil)
        #expect(try args.optionalString("nothing") == nil)
        #expect(throws: ToolError.self) { try args.string("path") }
    }

    @Test func aDoubleEncodedObjectIsUnwrapped() throws {
        let args = try arguments(#""{\"path\":\"a.txt\",\"limit\":\"4\"}""#)
        #expect(try args.string("path") == "a.txt")
        #expect(try args.optionalInt("limit") == 4)
    }

    @Test func whatCannotBeReadUnambiguouslyStillFails() throws {
        let args = try arguments(#"{"n":"many","b":"yes","f":1.5,"s":3,"list":{"a":1},"text":"notjson"}"#)
        #expect(throws: ToolError.self) { try args.optionalInt("n") }
        #expect(throws: ToolError.self) { try args.optionalInt("f") }
        #expect(throws: ToolError.self) { try args.optionalBool("b") }
        #expect(throws: ToolError.self) { try args.optionalString("s") }
        #expect(throws: ToolError.self) { try args.optionalStringArray("list") }
        #expect(throws: ToolError.self) { try ToolArguments(json: #""just text""#) }
        #expect(throws: ToolError.self) { try ToolArguments(json: "[1]") }
    }
}
