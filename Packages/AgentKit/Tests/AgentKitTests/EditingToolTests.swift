import Foundation
import Testing
@testable import AgentKit

private struct Fixture {
    let project: TempProject
    let ledger = ReadLedger()
    let log = CheckpointLog()
    let run: RunID

    init(files: [String: String] = [:]) async throws {
        project = try TempProject(files: files)
        run = await log.beginRun(label: "test")
    }

    var workspace: DiskAgentWorkspace { project.workspace }

    func context(checkpoint: Bool = true) -> ToolContext {
        ToolContext(
            workspace: workspace, ledger: ledger, callID: "c",
            checkpoint: checkpoint ? CheckpointScope(log: log, run: run) : nil)
    }

    func call(_ tool: any AgentTool, _ arguments: String, checkpoint: Bool = true) async -> ToolOutput {
        await tool.execute(argumentsJSON: arguments, context: context(checkpoint: checkpoint))
    }

    func read(_ path: String) async -> ToolOutput {
        await call(ReadFileTool(), #"{"path":"\#(path)"}"#)
    }

    func disk(_ path: String) throws -> String {
        try String(contentsOf: project.root.appendingPathComponent(path), encoding: .utf8)
    }
}

@Suite struct EditFileToolTests {
    private let edit = EditFileTool()

    @Test func replacesAUniqueMatchAndShowsTheResult() async throws {
        let f = try await Fixture(files: ["A.java": "class A {\n    int x = 1;\n    int y = 2;\n}\n"])
        _ = await f.read("A.java")
        let output = await f.call(edit, #"{"path":"A.java","old_string":"int x = 1;","new_string":"int x = 42;"}"#)
        #expect(!output.isError, "\(output.text)")
        #expect(try f.disk("A.java") == "class A {\n    int x = 42;\n    int y = 2;\n}\n")
        #expect(output.text.contains("Edited A.java: replaced 1 occurrence, starting at line 2."))
        #expect(output.text.contains("     2\t    int x = 42;"))
    }

    @Test func refusesAFileTheModelHasNotRead() async throws {
        let f = try await Fixture(files: ["A.txt": "one\n"])
        let output = await f.call(edit, #"{"path":"A.txt","old_string":"one","new_string":"two"}"#)
        #expect(output == .error("Read A.txt with read_file before changing it."))
        #expect(try f.disk("A.txt") == "one\n")
    }

    @Test func refusesAFileThatChangedSinceItWasRead() async throws {
        let f = try await Fixture(files: ["A.txt": "one\n"])
        _ = await f.read("A.txt")
        try f.project.write("A.txt", "one edited by the user\n")
        let output = await f.call(edit, #"{"path":"A.txt","old_string":"one","new_string":"two"}"#)
        #expect(output.isError && output.text.contains("changed since you last read it"))
        #expect(try f.disk("A.txt") == "one edited by the user\n")
    }

    @Test func aSecondEditNeedsNoReReadBecauseTheToolKnowsWhatItWrote() async throws {
        let f = try await Fixture(files: ["A.txt": "a b c\n"])
        _ = await f.read("A.txt")
        _ = await f.call(edit, #"{"path":"A.txt","old_string":"a","new_string":"X"}"#)
        let second = await f.call(edit, #"{"path":"A.txt","old_string":"c","new_string":"Z"}"#)
        #expect(!second.isError, "\(second.text)")
        #expect(try f.disk("A.txt") == "X b Z\n")
    }

    @Test func zeroMatchesAndSeveralMatchesAreExplained() async throws {
        let f = try await Fixture(files: ["A.txt": "foo\nbar\nfoo\n"])
        _ = await f.read("A.txt")
        let none = await f.call(edit, #"{"path":"A.txt","old_string":"baz","new_string":"x"}"#)
        #expect(none.isError && none.text.contains("was not found in A.txt"))
        let many = await f.call(edit, #"{"path":"A.txt","old_string":"foo","new_string":"x"}"#)
        #expect(many.isError && many.text.contains("appears 2 times in A.txt (lines 1, 3)"))
        #expect(try f.disk("A.txt") == "foo\nbar\nfoo\n", "a refused edit changes nothing")
    }

    @Test func replaceAllChangesEveryOccurrence() async throws {
        let f = try await Fixture(files: ["A.txt": "foo\nbar\nfoo\n"])
        _ = await f.read("A.txt")
        let output = await f.call(edit, #"{"path":"A.txt","old_string":"foo","new_string":"qux","replace_all":true}"#)
        #expect(output.text.contains("replaced 2 occurrences"))
        #expect(try f.disk("A.txt") == "qux\nbar\nqux\n")
    }

    @Test func matchesAcrossLinesAndKeepsCRLF() async throws {
        let f = try await Fixture(files: ["Win.txt": "one\r\ntwo\r\nthree\r\n"])
        _ = await f.read("Win.txt")
        let output = await f.call(edit, #"{"path":"Win.txt","old_string":"one\ntwo","new_string":"1\n2\n2b"}"#)
        #expect(!output.isError, "\(output.text)")
        #expect(try f.disk("Win.txt") == "1\r\n2\r\n2b\r\nthree\r\n")
    }

    @Test func overlappingLookalikesAreNotDoubleCounted() async throws {
        let f = try await Fixture(files: ["A.txt": "aaa\n"])
        _ = await f.read("A.txt")
        // "aa" occurs once without overlap, so this is a unique match and replaces the first two.
        let output = await f.call(edit, #"{"path":"A.txt","old_string":"aa","new_string":"b"}"#)
        #expect(!output.isError)
        #expect(try f.disk("A.txt") == "ba\n")
    }

    @Test func handlesNonBMPCharactersBeforeTheMatch() async throws {
        let f = try await Fixture(files: ["U.txt": "😀 emoji then target\n"])
        _ = await f.read("U.txt")
        let output = await f.call(edit, #"{"path":"U.txt","old_string":"target","new_string":"goal"}"#)
        #expect(!output.isError, "\(output.text)")
        #expect(try f.disk("U.txt") == "😀 emoji then goal\n")
    }

    @Test func rejectsEmptyOrIdenticalStringsAndBadPaths() async throws {
        let f = try await Fixture(files: ["A.txt": "one\n"])
        _ = await f.read("A.txt")
        #expect(await f.call(edit, #"{"path":"A.txt","old_string":"","new_string":"x"}"#).isError)
        #expect(await f.call(edit, #"{"path":"A.txt","old_string":"one","new_string":"one"}"#).isError)
        #expect(await f.call(edit, #"{"path":"../outside.txt","old_string":"a","new_string":"b"}"#).isError)
        #expect(await f.call(edit, #"{"path":"missing.txt","old_string":"a","new_string":"b"}"#) == .error("missing.txt does not exist."))
    }

    @Test func neverWritesVersionControlOrBuildOutput() async throws {
        let f = try await Fixture(files: [
            ".git/config": "x", "build.gradle": "", "build/out.txt": "x", "src/main/java/com/x/build/B.java": "class B {}\n",
        ])
        for path in [".git/config", "build/out.txt"] {
            _ = await f.read(path)
            let output = await f.call(edit, #"{"path":"\#(path)","old_string":"x","new_string":"y"}"#)
            #expect(output.isError && output.text.contains("does not write there"), "\(path): \(output.text)")
        }
        // A Java package named `build` is source, not output.
        _ = await f.read("src/main/java/com/x/build/B.java")
        let source = await f.call(edit, #"{"path":"src/main/java/com/x/build/B.java","old_string":"class B","new_string":"class C"}"#)
        #expect(!source.isError, "\(source.text)")
    }

    @Test func recordsACheckpointBeforeTheFirstChange() async throws {
        let f = try await Fixture(files: ["A.txt": "orig\n"])
        _ = await f.read("A.txt")
        _ = await f.call(edit, #"{"path":"A.txt","old_string":"orig","new_string":"one"}"#)
        _ = await f.call(edit, #"{"path":"A.txt","old_string":"one","new_string":"two"}"#)
        let changes = await f.log.changes(in: f.run)
        #expect(changes.count == 1)
        #expect(changes[0].original == "orig\n", "the original is the text before the run's first change")
    }
}

@Suite struct WriteFileToolTests {
    private let write = WriteFileTool()

    @Test func createsANewFileWithItsFolders() async throws {
        let f = try await Fixture()
        let output = await f.call(write, #"{"path":"src/new/Hello.java","content":"class Hello {}\n"}"#)
        #expect(output == ToolOutput("Created src/new/Hello.java (1 lines)."))
        #expect(try f.disk("src/new/Hello.java") == "class Hello {}\n")
        #expect(await f.log.changes(in: f.run).first?.original == nil)
    }

    @Test func overwritingNeedsAFreshRead() async throws {
        let f = try await Fixture(files: ["A.txt": "old\n"])
        let unread = await f.call(write, #"{"path":"A.txt","content":"new\n"}"#)
        #expect(unread == .error("Read A.txt with read_file before changing it."))
        _ = await f.read("A.txt")
        let output = await f.call(write, #"{"path":"A.txt","content":"new\n"}"#)
        #expect(output == ToolOutput("Overwrote A.txt (1 lines)."))
        #expect(try f.disk("A.txt") == "new\n")
    }

    @Test func overwritingKeepsACRLFFilesLineEndings() async throws {
        let f = try await Fixture(files: ["W.txt": "a\r\nb\r\n"])
        _ = await f.read("W.txt")
        _ = await f.call(write, #"{"path":"W.txt","content":"x\ny\nz\n"}"#)
        #expect(try f.disk("W.txt") == "x\r\ny\r\nz\r\n")
    }

    @Test func refusesIdenticalContentBinaryFilesAndHugeContent() async throws {
        let f = try await Fixture(files: ["A.txt": "same\n"])
        _ = await f.read("A.txt")
        #expect(await f.call(write, #"{"path":"A.txt","content":"same\n"}"#).isError)
        try Data([0xff, 0xfe, 0x00]).write(to: f.project.root.appendingPathComponent("b.dat"))
        let binary = await f.call(write, #"{"path":"b.dat","content":"x"}"#)
        #expect(binary.isError && binary.text.contains("not a UTF-8 text file"))
        let huge = String(repeating: "x", count: WriteFileTool.maxBytes + 1)
        #expect(await f.call(write, #"{"path":"big.txt","content":"\#(huge)"}"#).isError)
    }

    @Test func staysInsideTheProject() async throws {
        let f = try await Fixture()
        #expect(await f.call(write, #"{"path":"../escape.txt","content":"x"}"#).isError)
        #expect(await f.call(write, #"{"path":"/tmp/escape.txt","content":"x"}"#).isError)
        #expect(await f.call(write, #"{"path":".git/hooks/pre-commit","content":"x"}"#).isError)
    }

    @Test func aReadOnlyWorkspaceRefusesEverything() async throws {
        struct ReadOnly: AgentWorkspace {
            var rootPath: String { "/" }
            func readText(path: String) async throws -> String { "x" }
            func listDirectory(path: String) async throws -> [DirectoryEntry] { [] }
            func allFiles() async throws -> [String] { [] }
            func search(_ query: SearchQuery) async throws -> SearchResults { SearchResults(matches: [], truncated: false) }
        }
        let ledger = ReadLedger()
        await ledger.record(path: "a", text: "x")
        let context = ToolContext(workspace: ReadOnly(), ledger: ledger, callID: "c")
        let output = await EditFileTool().execute(
            argumentsJSON: #"{"path":"a","old_string":"x","new_string":"y"}"#, context: context)
        #expect(output == .error("This workspace is read-only."))
    }
}

@Suite struct SecretFileTests {
    @Test func classifiesLikelyCredentialFiles() {
        for path in [".env", "app/.env.local", "prod.env", "keys/server.pem", "a/b/id_rsa", "id_ed25519.pub", "x.p12", "release.keystore", ".netrc"] {
            #expect(SecretFilePolicy.isLikelySecret(path), "\(path)")
        }
        for path in ["env.md", "src/Environment.java", "keyboard.txt", "README.md", "key.java"] {
            #expect(!SecretFilePolicy.isLikelySecret(path), "\(path)")
        }
    }

    @Test func readFileRefusesThemAndGrepSkipsThem() async throws {
        let f = try await Fixture(files: [".env": "API_KEY=hunter2\n", "src/A.java": "String key = \"hunter2\";\n"])
        let read = await f.read(".env")
        #expect(read.isError && read.text.contains("looks like it holds credentials"))
        let grep = await f.call(GrepTool(), #"{"pattern":"hunter2"}"#)
        #expect(grep.text == "src/A.java:1: String key = \"hunter2\";")
    }

    @Test func userPatternsExtendTheBuiltInListForReadAndGrep() async throws {
        let f = try await Fixture(files: [
            "config/prod.yaml": "token: hunter2\n", "secrets/db.txt": "hunter2\n", "src/A.java": "// hunter2\n", ".env": "hunter2\n",
        ])
        let tools = ReadOnlyTools.all(secretPatterns: ["config/*.yaml", "# a comment", "", "secrets/**", "[unbalanced{"])
        let read = tools[0], grep = tools[3]
        for path in ["config/prod.yaml", "secrets/db.txt", ".env"] {
            let output = await f.call(read, #"{"path":"\#(path)"}"#)
            #expect(output.isError && output.text.contains("credentials"), "\(path)")
        }
        #expect(await f.call(read, #"{"path":"src/A.java"}"#).isError == false)
        #expect(await f.call(grep, #"{"pattern":"hunter2"}"#).text == "src/A.java:1: // hunter2")
        #expect(SecretFilePolicy.patterns(from: ["# c", "  ", "*.vault"]).count == 1, "comments and blanks are not patterns")
    }
}

@Suite struct EditNotFoundHintTests {
    private let source = """
    def validate_email(value):
        text = str(value).strip()
        text = " ".join(text.split())
        return text


    def validate_tag(value):
        text = str(value).strip()
        text = " ".join(text.split())
        return text

    """

    private func edit(_ f: Fixture, old: String, new: String) async -> ToolOutput {
        _ = await f.read("v.py")
        let arguments = JSONValue.object(["path": .string("v.py"), "old_string": .string(old), "new_string": .string(new)])
        return await f.call(EditFileTool(), (try? arguments.serialized()) ?? "{}")
    }

    @Test func wrongIndentationShowsTheLinesAsTheFileHasThem() async throws {
        let f = try await Fixture(files: ["v.py": source])
        let output = await edit(f, old: "text = str(value).strip()\ntext = \" \".join(text.split())", new: "text = clean(value)")
        #expect(output.isError)
        #expect(output.text.contains("once spacing is ignored (2 places match this way; this is the first)"), "\(output.text)")
        #expect(output.text.contains("lines 2–3"), "\(output.text)")
        #expect(output.text.contains("    text = str(value).strip()\n    text = \" \".join(text.split())"), "the exact, indented lines to copy")
        #expect(try f.disk("v.py") == source, "nothing changed")
    }

    @Test func tabsVersusSpacesAndTrailingWhitespaceAreNearMatchesToo() async throws {
        let f = try await Fixture(files: ["v.py": "def f():\n    a = 1   \n    b = 2\n"])
        let output = await edit(f, old: "\ta = 1\n\tb = 2", new: "pass")
        #expect(output.text.contains("lines 2–3") && output.text.contains("    a = 1   \n    b = 2"), "\(output.text)")
    }

    @Test func anEditThatAlreadyWentThroughIsRecognised() async throws {
        let f = try await Fixture(files: ["v.py": "x = clean(value)\n"])
        let output = await edit(f, old: "x = raw(value)", new: "x = clean(value)")
        #expect(output.text.contains("new_string is already in the file at line 1") && output.text.contains("may already have been made"), "\(output.text)")
    }

    @Test func unrelatedTextKeepsTheOriginalMessageWithoutGuessing() async throws {
        let f = try await Fixture(files: ["v.py": source])
        let output = await edit(f, old: "nothing like this", new: "something else")
        #expect(output.text == "Error: old_string was not found in v.py. It must match the file exactly, including indentation and line breaks. Re-read the lines and copy the text again.")
    }

    @Test func aBlankOnlyOldStringIsNeverANearMatch() async throws {
        #expect(EditSupport.nearMatch(of: "\n  \n", in: source) == nil)
        #expect(EditSupport.nearMatch(of: "x", in: "") == nil)
    }
}
