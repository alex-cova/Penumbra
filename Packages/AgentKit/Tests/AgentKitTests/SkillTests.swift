import Foundation
import Testing
@testable import AgentKit

@Suite struct MarkdownFrontmatterTests {
    @Test func readsScalarsQuotesListsAndBlocks() {
        let document = MarkdownFrontmatter.parse("""
        ---
        name: review
        Description: "Review a diff: carefully"
        allowed-tools: [Bash(git diff:*), Read, "Edit(src/**)"]
        tags:
          - one
          - 'two'
        notes: |
          line one
          line two
        summary: >
          folded
          text
        # a comment
        ---
        # Title

        Body text.
        """)
        #expect(document.text("name") == "review")
        #expect(document.text("description") == "Review a diff: carefully", "keys are case-insensitive and quotes come off")
        #expect(document.list("allowed-tools") == ["Bash(git diff:*)", "Read", "Edit(src/**)"])
        #expect(document.list("tags") == ["one", "two"])
        #expect(document.text("notes") == "line one\nline two")
        #expect(document.text("summary") == "folded text")
        #expect(document.body == "# Title\n\nBody text.")
    }

    @Test func aCommaInsideParenthesesDoesNotSplitAListItem() {
        let document = MarkdownFrontmatter.parse("---\nallowed-tools: [Bash(git add:*, x), Read]\n---\nbody")
        #expect(document.list("allowed-tools") == ["Bash(git add:*, x)", "Read"])
    }

    @Test func commaSeparatedTextCountsAsAList() {
        let document = MarkdownFrontmatter.parse("---\nallowed-tools: Read, Grep\n---\nbody")
        #expect(document.list("allowed-tools") == ["Read", "Grep"])
    }

    @Test func aFileWithoutAHeaderIsAllBody() {
        #expect(MarkdownFrontmatter.parse("Just text\n").body == "Just text\n")
        #expect(MarkdownFrontmatter.parse("").body == "")
        let unclosed = "---\nname: x\nno end"
        #expect(MarkdownFrontmatter.parse(unclosed).body == unclosed, "a header that never closes is not one")
        #expect(MarkdownFrontmatter.parse(unclosed).metadata.isEmpty)
    }

    @Test func windowsLineEndingsAndABOMAreHandled() {
        let document = MarkdownFrontmatter.parse("\u{FEFF}---\r\nname: crlf\r\n---\r\nBody\r\n")
        #expect(document.text("name") == "crlf")
        #expect(document.body == "Body")
    }

    @Test func anEmptyValueIsMissing() {
        let document = MarkdownFrontmatter.parse("---\ndescription:\nname: x\n---\nb")
        #expect(document.text("description") == nil)
        #expect(document.text("name") == "x")
    }
}

@Suite struct CommandTemplateTests {
    private func template(_ body: String, name: String = "c") -> CommandTemplate { CommandTemplate(name: name, description: "", body: body) }

    @Test func argumentsFillTheirPlaceholders() {
        let command = template("Fix $ARGUMENTS now. First: $1, second: $2, third: $3.")
        #expect(command.expand(arguments: "the parser \"two words\"") == "Fix the parser \"two words\" now. First: the, second: parser, third: two words.")
    }

    @Test func aMissingArgumentIsEmptyAndTheBodyIsOtherwiseUntouched() {
        #expect(template("a $1 b $2 c").expand(arguments: "x") == "a x b  c")
        #expect(template("price is $5 and $ alone and $$").expand(arguments: "") == "price is  and $ alone and $$", "$5 is a positional; a lone $ is text")
        #expect(template("keep $ARGUMENTSX").expand(arguments: "a") == "keep aX")
    }

    @Test func aCommandThatNeverMentionsItsArgumentsStillGetsThem() {
        #expect(template("Run the linter.").expand(arguments: "src/") == "Run the linter.\n\nARGUMENTS: src/")
        #expect(template("Run the linter.").expand(arguments: "  ") == "Run the linter.")
    }

    @Test func theNameComesFromThePathAndTheDescriptionFromTheHeaderOrTheFirstLine() {
        let nested = CommandTemplate(relativePath: "frontend/lint.md", contents: "---\ndescription: Lint it\nargument-hint: <dir>\nallowed-tools: Bash(npm run lint:*)\n---\n# Heading\nDo it.", source: ".claude/commands")
        #expect(nested.name == "frontend:lint")
        #expect(nested.description == "Lint it" && nested.argumentHint == "<dir>")
        #expect(nested.allowedTools == ["Bash(npm run lint:*)"])
        #expect(nested.source == ".claude/commands")

        let plain = CommandTemplate(relativePath: "ship.md", contents: "# Ship\n\nTag and push the release.\nMore.", source: "")
        #expect(plain.name == "ship" && plain.description == "Tag and push the release.")
    }

    @Test func shellSubstitutionIsRecognizedSoTheHostCanSayItIsNotRun() {
        #expect(template("Status: !`git status`").usesShellSubstitution)
        #expect(!template("No shell here").usesShellSubstitution)
    }
}

@Suite struct SkillCatalogTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skills-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, _ root: URL, _ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func loadsSkillsAndCommandsFromTheirFolders() throws {
        let root = try makeRoot()
        try write("---\nname: reviewer\ndescription: Reviews diffs\n---\nLook at the diff.", root, "skills/review-diff/SKILL.md")
        try write("No header, so the folder name is the name.", root, "skills/plain/SKILL.md")
        try write("not a skill", root, "skills/notes.txt")
        try write("---\ndescription: Lint\n---\nLint $ARGUMENTS", root, "commands/lint.md")
        try write("Deploy.", root, "commands/ops/deploy.md")
        try write("hidden", root, "commands/.secret.md")

        let catalog = SkillCatalog.load(
            skillFolders: [.init(url: root.appendingPathComponent("skills"), label: ".claude/skills")],
            commandFolders: [.init(url: root.appendingPathComponent("commands"), label: ".claude/commands")])
        #expect(catalog.skills.map(\.name) == ["plain", "reviewer"])
        #expect(catalog.skill(named: "REVIEWER")?.description == "Reviews diffs", "lookup ignores case")
        #expect(catalog.skill(named: "plain")?.description == "No header, so the folder name is the name.")
        #expect(catalog.commands.map(\.name) == ["lint", "ops:deploy"])
        #expect(catalog.command(named: "ops:deploy")?.source == ".claude/commands")
        #expect(!catalog.isEmpty)
    }

    @Test func anEarlierFolderWinsWhenTwoUseAName() throws {
        let root = try makeRoot()
        try write("---\ndescription: from the project\n---\nproject", root, "project/skills/shared/SKILL.md")
        try write("---\ndescription: from the user\n---\nuser", root, "user/skills/shared/SKILL.md")
        try write("project command", root, "project/commands/go.md")
        try write("user command", root, "user/commands/go.md")
        try write("only user", root, "user/commands/extra.md")

        let catalog = SkillCatalog.load(
            skillFolders: [.init(url: root.appendingPathComponent("project/skills"), label: "project"),
                           .init(url: root.appendingPathComponent("user/skills"), label: "user")],
            commandFolders: [.init(url: root.appendingPathComponent("project/commands"), label: "project"),
                             .init(url: root.appendingPathComponent("user/commands"), label: "user")])
        #expect(catalog.skills.count == 1 && catalog.skill(named: "shared")?.body == "project")
        #expect(catalog.command(named: "go")?.body == "project command")
        #expect(catalog.command(named: "extra")?.source == "user")
    }

    @Test func missingFoldersAndOversizedFilesAreSkipped() throws {
        let root = try makeRoot()
        try write(String(repeating: "x", count: SkillCatalog.maxFileBytes + 1), root, "skills/huge/SKILL.md")
        try write("ok", root, "skills/fine/SKILL.md")
        let catalog = SkillCatalog.load(
            skillFolders: [.init(url: root.appendingPathComponent("nowhere"), label: "a"), .init(url: root.appendingPathComponent("skills"), label: "b")],
            commandFolders: [])
        #expect(catalog.skills.map(\.name) == ["fine"])
    }

    @Test func namesAreMadeTypable() throws {
        let root = try makeRoot()
        try write("---\nname: My Skill / v2\n---\nbody", root, "skills/dir/SKILL.md")
        try write("---\nname: \"///\"\n---\nbody", root, "skills/junk/SKILL.md")
        let catalog = SkillCatalog.load(skillFolders: [.init(url: root.appendingPathComponent("skills"), label: "s")], commandFolders: [])
        #expect(catalog.skills.map(\.name) == ["My-Skill---v2"])
    }

    @Test func theFingerprintChangesWithWhatTheModelWouldSee() {
        func skill(_ body: String, description: String = "d") -> Skill {
            Skill(name: "s", description: description, body: body, directory: URL(fileURLWithPath: "/tmp/s"))
        }
        let base = SkillCatalog(skills: [skill("one")]).fingerprint
        #expect(base == SkillCatalog(skills: [skill("one")]).fingerprint)
        #expect(base != SkillCatalog(skills: [skill("two")]).fingerprint)
        #expect(base != SkillCatalog(skills: [skill("one", description: "other")]).fingerprint)
        #expect(base != SkillCatalog().fingerprint)
        let commandOnly = SkillCatalog(commands: [CommandTemplate(name: "c", description: "", body: "b")])
        #expect(commandOnly.fingerprint == SkillCatalog().fingerprint, "commands are run by the user, not seen by the model")
    }
}

@Suite struct SkillToolTests {
    private func fixture() throws -> (catalog: SkillCatalog, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skilltool-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let directory = root.appendingPathComponent("skills/api", isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("references"), withIntermediateDirectories: true)
        try "Call the API like this.".write(to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "endpoint list".write(to: directory.appendingPathComponent("references/endpoints.md"), atomically: true, encoding: .utf8)
        try "#!/bin/sh".write(to: directory.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)
        try "top secret".write(to: root.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
        let catalog = SkillCatalog.load(skillFolders: [.init(url: root.appendingPathComponent("skills"), label: "s")], commandFolders: [])
        return (catalog, root)
    }

    private func run(_ tool: SkillTool, _ json: String) async -> ToolOutput {
        let project = try! TempProject()
        let context = ToolContext(workspace: project.workspace, ledger: ReadLedger(), callID: "c")
        return await tool.execute(argumentsJSON: json, context: context)
    }

    @Test func theDefinitionListsEverySkillWithItsDescription() throws {
        let (catalog, _) = try fixture()
        let description = SkillTool(catalog: catalog).definition.description
        #expect(description.contains("- api: Call the API like this."))
        #expect(SkillTool(catalog: catalog).definition.name == "skill")
    }

    @Test func aSkillReturnsItsInstructionsAndNamesTheFilesBesideThem() async throws {
        let (catalog, _) = try fixture()
        let output = await run(SkillTool(catalog: catalog), #"{"name":"API"}"#)
        #expect(!output.isError)
        #expect(output.text.hasPrefix("Call the API like this."))
        #expect(output.text.contains("references/endpoints.md") && output.text.contains("run.sh"))
        #expect(!output.text.contains("SKILL.md,"), "the skill's own file is not listed")
    }

    @Test func aFileInsideTheFolderCanBeRead() async throws {
        let (catalog, _) = try fixture()
        let output = await run(SkillTool(catalog: catalog), #"{"name":"api","file":"references/endpoints.md"}"#)
        #expect(output.text == "endpoint list")
    }

    @Test func nothingOutsideTheFolderCanBeReadNotEvenThroughASymlink() async throws {
        let (catalog, root) = try fixture()
        let tool = SkillTool(catalog: catalog)
        let parent = await run(tool, #"{"name":"api","file":"../../outside.txt"}"#)
        #expect(parent.isError && parent.text.contains("outside the skill's folder"))
        let absolute = await run(tool, #"{"name":"api","file":"/etc/hosts"}"#)
        #expect(absolute.isError)

        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("skills/api/link.txt"), withDestinationURL: root.appendingPathComponent("outside.txt"))
        let linked = await run(tool, #"{"name":"api","file":"link.txt"}"#)
        #expect(linked.isError && !linked.text.contains("top secret"), "a symlink out of the folder is followed to where it really goes")
    }

    @Test func unknownSkillsMissingFilesAndBinaryFilesAreErrorsTheModelCanActOn() async throws {
        let (catalog, root) = try fixture()
        let tool = SkillTool(catalog: catalog)
        let unknown = await run(tool, #"{"name":"nope"}"#)
        #expect(unknown.isError && unknown.text.contains("Available: api"))
        let missing = await run(tool, #"{"name":"api","file":"gone.md"}"#)
        #expect(missing.isError && missing.text.contains("does not exist"))
        try Data([0xFF, 0xFE, 0x00, 0x80]).write(to: root.appendingPathComponent("skills/api/blob.bin"))
        let binary = await run(tool, #"{"name":"api","file":"blob.bin"}"#)
        #expect(binary.isError && binary.text.contains("not a text file"))
    }

    @Test func aLongListOfSkillsIsCappedInTheDefinition() {
        let skills = (0..<400).map {
            Skill(name: "skill-\($0)", description: String(repeating: "d", count: 200), body: "b", directory: URL(fileURLWithPath: "/tmp/\($0)"))
        }
        let description = SkillTool(catalog: SkillCatalog(skills: skills)).definition.description
        #expect(description.utf8.count < SkillTool.maxCatalogBytes + 1_500)
        #expect(description.contains("more skills exist"))
    }
}
