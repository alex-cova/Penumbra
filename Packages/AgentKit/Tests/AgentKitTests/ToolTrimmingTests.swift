import Foundation
import Testing
@testable import AgentKit

@Suite struct ToolTrimmingTests {
    @Test func aShortDescriptionIsOnlyTidied() {
        #expect(ToolDefinitionTrimmer.trimDescription("Reads a file.\n\n  Fast.  ", limit: 240) == "Reads a file. Fast.")
        #expect(ToolDefinitionTrimmer.trimDescription("Anything at all. Even this.", limit: .max) == "Anything at all. Even this.")
    }

    @Test func aLongDescriptionKeepsWholeSentencesUpToTheLimit() {
        let text = "Create a new issue in a repository. Requires write access to the repository. "
            + "The title is required and the body may use Markdown. Labels must already exist. Assignees must be collaborators."
        let trimmed = ToolDefinitionTrimmer.trimDescription(text, limit: 120)
        #expect(trimmed == "Create a new issue in a repository. Requires write access to the repository.")
        #expect(trimmed.count <= 120, "whole sentences, never past the limit")
        #expect(!trimmed.hasSuffix(" "))
    }

    @Test func theFirstSentenceSurvivesEvenWhenItIsLong() {
        let long = "Search " + String(repeating: "everything in the workspace by name and content ", count: 4) + "carefully. Second sentence."
        let trimmed = ToolDefinitionTrimmer.trimDescription(long, limit: 50)
        #expect(trimmed.hasPrefix("Search everything"))
        #expect(!trimmed.contains("Second"))
        let huge = String(repeating: "word ", count: 400) + "end."
        let capped = ToolDefinitionTrimmer.trimDescription(huge, limit: 50)
        #expect(capped.count <= 151)
        #expect(capped.hasSuffix("…"))
    }

    @Test func aDotInsideAWordOrAnAbbreviationDoesNotEndASentence() {
        let text = "Read config.json from the project, e.g. the root one. Then parse it. Third sentence here is long enough to matter. Fourth."
        let trimmed = ToolDefinitionTrimmer.trimDescription(text, limit: 60)
        #expect(trimmed.hasPrefix("Read config.json from the project, e.g. the root one."))
    }

    @Test func trimmingTwiceChangesNothing() {
        let text = String(repeating: "A sentence of reasonable length goes here. ", count: 12)
        let once = ToolDefinitionTrimmer.trimDescription(text, limit: 200)
        #expect(ToolDefinitionTrimmer.trimDescription(once, limit: 200) == once)
        let note = ToolDefinitionTrimmer.trimNote(String(repeating: "alpha beta gamma ", count: 30), limit: 100)
        #expect(ToolDefinitionTrimmer.trimNote(note, limit: 100).count <= note.count + 1)
    }

    @Test func aNoteIsCutAtAWordAndMarked() {
        let note = ToolDefinitionTrimmer.trimNote("The repository owner, which is a user or an organization and must exist already on the host", limit: 40)
        #expect(note == "The repository owner, which is a user or…")
        #expect(ToolDefinitionTrimmer.trimNote("short", limit: 40) == "short")
    }

    private let schema: JSONValue = [
        "$schema": "http://json-schema.org/draft-07/schema#",
        "type": "object",
        "title": "CreateIssue",
        "properties": [
            "title": ["type": "string", "title": "Title", "description": "The issue title. Keep it short and specific. It shows in every list of issues in the repository and in notifications sent to everyone watching, so make it count and make it clear."],
            "labels": ["type": "array", "items": ["type": "string", "examples": ["bug"]], "description": "Labels"],
            "state": ["type": "string", "enum": ["open", "closed"], "default": "open"],
            "owner": ["type": "string", "$comment": "internal"],
        ],
        "required": ["title", "owner"],
        "additionalProperties": false,
    ]

    @Test func aSchemaLosesAnnotationsAndLongNotesButNothingTheModelNeeds() {
        let trimmed = ToolDefinitionTrimmer.trimSchema(schema, .standard)
        #expect(trimmed["$schema"] == nil && trimmed["title"] == nil)
        #expect(trimmed["properties"]?["title"] != nil, "a parameter called title is not an annotation")
        #expect(trimmed["properties"]?["title"]?["title"] == nil)
        #expect(trimmed["properties"]?["labels"]?["items"]?["examples"] == nil)
        #expect(trimmed["properties"]?["owner"]?["$comment"] == nil)
        #expect(trimmed["required"] == ["title", "owner"])
        #expect(trimmed["properties"]?["state"]?["enum"] == ["open", "closed"])
        #expect(trimmed["properties"]?["state"]?["default"] == "open")
        #expect(trimmed["additionalProperties"] == false)
        #expect(trimmed["properties"]?["labels"]?["items"]?["type"] == "string")
        let note = trimmed["properties"]?["title"]?["description"]?.stringValue ?? ""
        #expect(note.count <= 161 && note.hasPrefix("The issue title."))
    }

    @Test func noneLeavesTheSchemaAsTheServerWroteIt() {
        #expect(ToolDefinitionTrimmer.trimSchema(schema, .none) == schema)
    }

    @Test func trimmingTheSchemaTwiceChangesNothing() {
        let once = ToolDefinitionTrimmer.trimSchema(schema, .standard)
        #expect(ToolDefinitionTrimmer.trimSchema(once, .standard) == once)
    }

    @Test func aToolInfoIsSmallerAfterwardsAndKeepsItsName() {
        let info = MCPToolInfo(
            name: "create_issue", description: String(repeating: "Creates an issue in a repository with all the usual fields. ", count: 12),
            inputSchema: schema, title: "Create", readOnlyHint: false)
        let trimmed = ToolDefinitionTrimmer.trim(info, .standard)
        #expect(trimmed.name == "create_issue")
        let before = ToolCost.characters(of: ToolDefinition(name: info.name, description: info.description, rawSchema: info.inputSchema))
        let after = ToolCost.characters(of: ToolDefinition(name: trimmed.name, description: trimmed.description, rawSchema: trimmed.inputSchema))
        #expect(trimmed.description.count <= 240)
        #expect(after < before * 3 / 4, "\(before) -> \(after)")
        #expect(ToolDefinitionTrimmer.trim(info, .none) == info)
    }
}
