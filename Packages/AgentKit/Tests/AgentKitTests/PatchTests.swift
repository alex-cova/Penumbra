import Foundation
import Testing
@testable import AgentKit

@Suite struct PatchParserTests {
    @Test func readsAGitStylePatchWithItsPreamble() throws {
        let patch = """
        diff --git a/src/A.java b/src/A.java
        index 83db48f..bf2a5c1 100644
        --- a/src/A.java
        +++ b/src/A.java
        @@ -1,3 +1,3 @@
         class A {
        -    int x = 1;
        +    int x = 2;
         }
        """
        let files = try PatchParser.parse(patch)
        #expect(files.count == 1 && files[0].path == "src/A.java")
        #expect(files[0].hunks.count == 1)
        #expect(files[0].hunks[0].oldLines == ["class A {", "    int x = 1;", "}"])
        #expect(files[0].hunks[0].newLines == ["class A {", "    int x = 2;", "}"])
    }

    @Test func pathsWithoutGitPrefixesAndWithTimestampsAreAccepted() throws {
        let files = try PatchParser.parse("--- src/A.java\t2026-01-01 10:00:00\n+++ src/A.java\t2026-01-02\n@@ -1 +1 @@\n-a\n+b\n")
        #expect(files[0].path == "src/A.java")
        #expect(try PatchParser.parse("--- x.txt\n+++ x.txt\n@@ -1 +1 @@\n-1\n+2\n")[0].path == "x.txt", "plain paths stay as they are")
        // Git's `a/` and `b/` are markers; a real directory called `a` shows up as `a/a/`.
        #expect(try PatchParser.parse("--- a/a/x.txt\n+++ b/a/x.txt\n@@ -1 +1 @@\n-1\n+2\n")[0].path == "a/x.txt")
    }

    @Test func creationsAndMultipleFiles() throws {
        let files = try PatchParser.parse("""
        --- /dev/null
        +++ b/New.java
        @@ -0,0 +1,2 @@
        +class New {
        +}
        --- a/Old.java
        +++ b/Old.java
        @@ -1 +1 @@
        -x
        +y
        """)
        #expect(files.map(\.path) == ["New.java", "Old.java"])
        #expect(files[0].isCreation && !files[1].isCreation)
    }

    @Test func wrongCountsAreToleratedBecauseModelsMiscount() throws {
        let files = try PatchParser.parse("--- a/A.txt\n+++ b/A.txt\n@@ -1,99 +1,99 @@\n a\n-b\n+c\n d\n")
        #expect(files[0].hunks[0].oldLines == ["a", "b", "d"])
    }

    @Test func aBlankContextLineWithoutItsSpaceIsStillBlankContext() throws {
        let files = try PatchParser.parse("--- a/A.txt\n+++ b/A.txt\n@@ -1,4 +1,4 @@\n a\n\n-b\n+c\n d\n")
        #expect(files[0].hunks[0].oldLines == ["a", "", "b", "d"])
    }

    @Test func trailingBlankLinesBetweenFilesAreNotContext() throws {
        let files = try PatchParser.parse("--- a/A.txt\n+++ b/A.txt\n@@ -1,2 +1,2 @@\n-a\n+b\n c\n\n--- a/B.txt\n+++ b/B.txt\n@@ -1 +1 @@\n-x\n+y\n")
        #expect(files[0].hunks[0].oldLines == ["a", "c"])
    }

    @Test func noNewlineMarkersAreRemembered() throws {
        let files = try PatchParser.parse("--- a/A.txt\n+++ b/A.txt\n@@ -1 +1 @@\n-a\n\\ No newline at end of file\n+b\n")
        #expect(files[0].hunks[0].oldMissingEOL && !files[0].hunks[0].newMissingEOL)
    }

    @Test func malformedPatchesNameTheProblem() {
        func message(_ patch: String) -> String {
            do { _ = try PatchParser.parse(patch); return "no error" } catch let error as PatchError { return error.message } catch { return "\(error)" }
        }
        #expect(message("") == "The patch is empty.")
        #expect(message("just some prose").contains("No file was found"))
        #expect(message("--- a/A\n+++ b/A\n").contains("has a header but no `@@` hunk"))
        #expect(message("--- a/A\n+++ b/A\n@@ nonsense @@\n-a\n").contains("Hunk 1 of A: the header is not understood"))
        #expect(message("--- a/A\n+++ b/A\n@@ -1 +1 @@\n-a\n+b\n*oops\n").contains("patch line 6 must start with a space, `-` or `+`"))
        #expect(message("--- a/A\n+++ b/A\n@@ -1 +1 @@\n a\n").contains("changes nothing"))
        #expect(message("--- a/A\n+++ b/A\n@@ -1 +1 @@\n-a\n+b\n--- a/A\n+++ b/A\n@@ -1 +1 @@\n-c\n+d\n").contains("appears twice"))
    }
}

private struct Fixture {
    let project: TempProject
    let ledger = ReadLedger()
    let log = CheckpointLog()
    let run: RunID

    init(files: [String: String]) async throws {
        project = try TempProject(files: files)
        run = await log.beginRun(label: "patch")
    }

    func context(tolerance: EditTolerance = .hosted, failures: EditFailureLog? = nil) -> ToolContext {
        ToolContext(
            workspace: project.workspace, ledger: ledger, callID: "c",
            checkpoint: CheckpointScope(log: log, run: run),
            editTolerance: tolerance, editFailures: failures)
    }

    func read(_ path: String) async { _ = await ReadFileTool().execute(argumentsJSON: #"{"path":"\#(path)"}"#, context: context()) }

    func patch(_ text: String, tolerance: EditTolerance = .hosted, failures: EditFailureLog? = nil) async -> ToolOutput {
        let argument = (try? JSONValue.string(text).serialized()) ?? "\"\""
        return await ApplyPatchTool().execute(
            argumentsJSON: #"{"patch":\#(argument)}"#, context: context(tolerance: tolerance, failures: failures))
    }

    func disk(_ path: String) -> String? { try? String(contentsOf: project.root.appendingPathComponent(path), encoding: .utf8) }
}

@Suite struct ApplyPatchToolTests {
    private let java = "class A {\n    int x = 1;\n    int y = 2;\n    int z = 3;\n}\n"

    @Test func appliesOneHunkAndShowsTheResult() async throws {
        let f = try await Fixture(files: ["A.java": java])
        await f.read("A.java")
        let output = await f.patch("--- a/A.java\n+++ b/A.java\n@@ -1,4 +1,4 @@\n class A {\n-    int x = 1;\n+    int x = 10;\n     int y = 2;\n     int z = 3;\n")
        #expect(!output.isError, "\(output.text)")
        #expect(f.disk("A.java") == "class A {\n    int x = 10;\n    int y = 2;\n    int z = 3;\n}\n")
        #expect(output.text.contains("Patched A.java: 1 hunk, +1 −1."))
        #expect(output.text.contains("     2\t    int x = 10;"))
    }

    @Test func thePreviewShowsTheChangeNotJustItsSurroundings() async throws {
        let f = try await Fixture(files: ["Calc.java": "package demo;\n\npublic class Calc {\n    int add() {\n        return 1;\n    }\n}\n"])
        await f.read("Calc.java")
        let output = await f.patch("--- a/Calc.java\n+++ b/Calc.java\n@@ -1,7 +1,11 @@\n package demo;\n \n public class Calc {\n     int add() {\n         return 1;\n     }\n+\n+    int sub() {\n+        return 0;\n+    }\n }\n")
        #expect(!output.isError, "\(output.text)")
        #expect(output.text.contains("+    int sub() {") == false, "the preview is numbered code, not diff text")
        #expect(output.text.contains("     8\t    int sub() {"), "\(output.text)")
        #expect(output.text.contains("    10\t    }"), "\(output.text)")
    }

    @Test func wrongLineNumbersDoNotMatterTheContextDecides() async throws {
        let f = try await Fixture(files: ["A.java": java])
        await f.read("A.java")
        let output = await f.patch("--- a/A.java\n+++ b/A.java\n@@ -40,3 +40,3 @@\n     int y = 2;\n-    int z = 3;\n+    int z = 30;\n }\n")
        #expect(!output.isError, "\(output.text)")
        #expect(f.disk("A.java")?.contains("int z = 30;") == true)
    }

    @Test func severalHunksInOneFileApplyAgainstTheOriginalNumbering() async throws {
        let text = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let f = try await Fixture(files: ["N.txt": text])
        await f.read("N.txt")
        let patch = """
        --- a/N.txt
        +++ b/N.txt
        @@ -2,3 +2,5 @@
         line 2
        +inserted a
        +inserted b
         line 3
         line 4
        @@ -17,3 +19,2 @@
         line 17
        -line 18
         line 19
        """
        let output = await f.patch(patch)
        #expect(!output.isError, "\(output.text)")
        let lines = try #require(f.disk("N.txt")).split(separator: "\n").map(String.init)
        #expect(lines.count == 21)
        #expect(Array(lines[1...4]) == ["line 2", "inserted a", "inserted b", "line 3"])
        #expect(!lines.contains("line 18"))
        #expect(output.text.contains("2 hunks, +2 −1"))
    }

    @Test func aMismatchNamesTheHunkAndTheLineThatDidNotMatchAndChangesNothing() async throws {
        let f = try await Fixture(files: ["A.java": java])
        await f.read("A.java")
        let output = await f.patch("--- a/A.java\n+++ b/A.java\n@@ -1,4 +1,4 @@\n class A {\n-    int x = 99;\n+    int x = 10;\n     int y = 2;\n")
        #expect(output.isError)
        #expect(output.text.contains("Hunk 1 (@@ -1,4 +1,4 @@) of A.java does not match the file."), "\(output.text)")
        #expect(output.text.contains("The first 1 line(s) match at line 1, then hunk line 2 expected `    int x = 99;` but the file has `    int x = 1;` at line 2."), "\(output.text)")
        #expect(f.disk("A.java") == java)
    }

    @Test func contextThatIsNowhereInTheFileSaysSo() async throws {
        let f = try await Fixture(files: ["A.java": java])
        await f.read("A.java")
        let output = await f.patch("--- a/A.java\n+++ b/A.java\n@@ -1 +1 @@\n-nothing like this\n+x\n")
        #expect(output.text.contains("Its first line was not found anywhere: expected `nothing like this`"), "\(output.text)")
    }

    @Test func contextThatMatchesSeveralPlacesIsAmbiguous() async throws {
        let f = try await Fixture(files: ["D.txt": "x\nA\nB\ny\nA\nB\nz\nA\nB\n"])
        await f.read("D.txt")
        let output = await f.patch("--- a/D.txt\n+++ b/D.txt\n@@ -50,2 +50,2 @@\n A\n-B\n+C\n")
        #expect(output.isError && output.text.contains("matches 3 places (lines 2, 5, 8)"), "\(output.text)")
        #expect(f.disk("D.txt") == "x\nA\nB\ny\nA\nB\nz\nA\nB\n")
    }

    @Test func aStatedPositionBreaksTheTieWhenItIsRight() async throws {
        let f = try await Fixture(files: ["D.txt": "x\nA\nB\ny\nA\nB\nz\n"])
        await f.read("D.txt")
        let output = await f.patch("--- a/D.txt\n+++ b/D.txt\n@@ -5,2 +5,2 @@\n A\n-B\n+C\n")
        #expect(!output.isError, "\(output.text)")
        #expect(f.disk("D.txt") == "x\nA\nB\ny\nA\nC\nz\n")
    }

    @Test func hunksMustFollowEachOtherInTheFile() async throws {
        let f = try await Fixture(files: ["N.txt": "1\n2\n3\n4\n5\n6\n"])
        await f.read("N.txt")
        let output = await f.patch("--- a/N.txt\n+++ b/N.txt\n@@ -5,1 +5,1 @@\n-5\n+five\n@@ -1,1 +1,1 @@\n-1\n+one\n")
        #expect(output.isError, "an out-of-order second hunk cannot match before the first one ended")
        #expect(f.disk("N.txt") == "1\n2\n3\n4\n5\n6\n")
    }

    @Test func allOrNothingAcrossFiles() async throws {
        let f = try await Fixture(files: ["A.txt": "a\n", "B.txt": "b\n"])
        await f.read("A.txt"); await f.read("B.txt")
        let output = await f.patch("--- a/A.txt\n+++ b/A.txt\n@@ -1 +1 @@\n-a\n+A\n--- a/B.txt\n+++ b/B.txt\n@@ -1 +1 @@\n-WRONG\n+B\n")
        #expect(output.isError && output.text.contains("of B.txt"))
        #expect(f.disk("A.txt") == "a\n", "the first file must not change when the second fails")
        #expect(await f.log.changes(in: f.run).isEmpty, "and nothing was checkpointed")
    }

    @Test func createsFilesAndRefusesToOverwriteOne() async throws {
        let f = try await Fixture(files: ["Old.txt": "old\n"])
        let output = await f.patch("--- /dev/null\n+++ b/pkg/New.java\n@@ -0,0 +1,3 @@\n+package pkg;\n+\n+class New {}\n")
        #expect(output == ToolOutput("Created pkg/New.java (3 lines)."))
        #expect(f.disk("pkg/New.java") == "package pkg;\n\nclass New {}\n")
        let clash = await f.patch("--- /dev/null\n+++ b/Old.txt\n@@ -0,0 +1 @@\n+x\n")
        #expect(clash.isError && clash.text.contains("already exists"))
        let mixed = await f.patch("--- /dev/null\n+++ b/Bad.txt\n@@ -0,0 +1,2 @@\n+a\n b\n")
        #expect(mixed.isError && mixed.text.contains("may only add lines"))
    }

    @Test func refusesDeletionsUnreadFilesStaleReadsAndMissingFiles() async throws {
        let f = try await Fixture(files: ["A.txt": "a\n"])
        #expect(await f.patch("--- a/A.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-a\n") == .error("A.txt: apply_patch cannot delete files."))
        #expect(await f.patch("--- a/A.txt\n+++ b/A.txt\n@@ -1 +1 @@\n-a\n+b\n") == .error("Read A.txt with read_file before changing it."))
        await f.read("A.txt")
        try f.project.write("A.txt", "a edited by the user\n")
        #expect((await f.patch("--- a/A.txt\n+++ b/A.txt\n@@ -1 +1 @@\n-a\n+b\n")).text.contains("changed since you last read it"))
        let missing = await f.patch("--- a/Nope.txt\n+++ b/Nope.txt\n@@ -1 +1 @@\n-a\n+b\n")
        #expect(missing.isError)
    }

    @Test func staysInsideTheProjectAndOutOfProtectedFolders() async throws {
        let f = try await Fixture(files: [".git/config": "x\n"])
        #expect((await f.patch("--- /dev/null\n+++ b/../escape.txt\n@@ -0,0 +1 @@\n+x\n")).isError)
        #expect((await f.patch("--- /dev/null\n+++ b/.git/hooks/pre-commit\n@@ -0,0 +1 @@\n+x\n")).text.contains("does not write there"))
    }

    @Test func keepsCRLFAndTheFinalNewlineState() async throws {
        let crlf = try await Fixture(files: ["W.txt": "one\r\ntwo\r\nthree\r\n"])
        await crlf.read("W.txt")
        let a = await crlf.patch("--- a/W.txt\n+++ b/W.txt\n@@ -1,3 +1,3 @@\n one\n-two\n+2\n+2b\n three\n")
        #expect(!a.isError, "\(a.text)")
        #expect(crlf.disk("W.txt") == "one\r\n2\r\n2b\r\nthree\r\n")

        let bare = try await Fixture(files: ["N.txt": "a\nb"])
        await bare.read("N.txt")
        let b = await bare.patch("--- a/N.txt\n+++ b/N.txt\n@@ -1,2 +1,2 @@\n a\n-b\n\\ No newline at end of file\n+c\n\\ No newline at end of file\n")
        #expect(!b.isError, "\(b.text)")
        #expect(bare.disk("N.txt") == "a\nc", "no newline before, none after")

        let gain = try await Fixture(files: ["G.txt": "a\nb"])
        await gain.read("G.txt")
        _ = await gain.patch("--- a/G.txt\n+++ b/G.txt\n@@ -1,2 +1,2 @@\n a\n-b\n\\ No newline at end of file\n+c\n")
        #expect(gain.disk("G.txt") == "a\nc\n", "a marker on the old side only means the new side gains its newline")
    }

    @Test func appendingAtTheEndOfAFileWithoutATrailingNewline() async throws {
        let f = try await Fixture(files: ["T.txt": "a\nb"])
        await f.read("T.txt")
        let output = await f.patch("--- a/T.txt\n+++ b/T.txt\n@@ -2,0 +3,1 @@\n+c\n")
        #expect(!output.isError, "\(output.text)")
        #expect(f.disk("T.txt") == "a\nb\nc\n")
    }

    @Test func aPatchedRunRevertsAsOneRun() async throws {
        let f = try await Fixture(files: ["A.txt": "a\n", "B.txt": "b\n"])
        await f.read("A.txt"); await f.read("B.txt")
        _ = await f.patch("--- a/A.txt\n+++ b/A.txt\n@@ -1 +1 @@\n-a\n+A\n--- a/B.txt\n+++ b/B.txt\n@@ -1 +1 @@\n-b\n+B\n--- /dev/null\n+++ b/C.txt\n@@ -0,0 +1 @@\n+c\n")
        #expect(f.disk("A.txt") == "A\n" && f.disk("B.txt") == "B\n" && f.disk("C.txt") == "c\n")
        let report = await f.log.revert(f.run, using: f.project.workspace)
        #expect(report.isComplete)
        #expect(f.disk("A.txt") == "a\n" && f.disk("B.txt") == "b\n" && f.disk("C.txt") == nil)
    }

    @Test func aWriteFailureHalfwayPutsTheFirstFileBack() async throws {
        let project = try TempProject(files: ["A.txt": "a\n", "B.txt": "b\n"])
        let failing = FailingWriteWorkspace(base: project.workspace, failOnPath: "B.txt")
        let ledger = ReadLedger()
        let log = CheckpointLog()
        let run = await log.beginRun(label: "x")
        let context = ToolContext(workspace: failing, ledger: ledger, callID: "c", checkpoint: CheckpointScope(log: log, run: run))
        for path in ["A.txt", "B.txt"] { _ = await ReadFileTool().execute(argumentsJSON: #"{"path":"\#(path)"}"#, context: context) }

        let patch = "--- a/A.txt\n+++ b/A.txt\n@@ -1 +1 @@\n-a\n+A\n--- a/B.txt\n+++ b/B.txt\n@@ -1 +1 @@\n-b\n+B\n"
        let argument = try JSONValue.string(patch).serialized()
        let output = await ApplyPatchTool().execute(argumentsJSON: #"{"patch":\#(argument)}"#, context: context)

        #expect(output.isError && output.text.contains("Applying B.txt failed"))
        #expect(output.text.contains("were put back, so nothing was changed"))
        #expect(try String(contentsOf: project.root.appendingPathComponent("A.txt"), encoding: .utf8) == "a\n")
        #expect(try String(contentsOf: project.root.appendingPathComponent("B.txt"), encoding: .utf8) == "b\n")
    }

    @Test func aCanonicalHunkRewritesOnlyTheMatchedLinesOfACRLFFile() async throws {
        let f = try await Fixture(files: ["a.txt": "keep\r\nhello \u{201C}world\u{201D}  \r\nuntouched\r\n"])
        await f.read("a.txt")
        let output = await f.patch("""
        --- a/a.txt
        +++ b/a.txt
        @@ -1,3 +1,3 @@
         keep
        -hello "world"
        +hello there
         untouched
        """)
        #expect(!output.isError)
        #expect(output.text.contains("normalizing"))
        #expect(f.disk("a.txt")?.debugDescription == "\"keep\\r\\nhello there\\r\\nuntouched\\r\\n\"")
    }

    @Test func aNormalizedNoOpIsReportedAndTheFileStays() async throws {
        let f = try await Fixture(files: ["a.txt": "hello\n"])
        await f.read("a.txt")
        let output = await f.patch("--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-hello \n+hello\n")
        #expect(output.isError)
        #expect(output.text.contains("nothing"))
        #expect(f.disk("a.txt") == "hello\n")
    }

    @Test func anIndentationShiftAppliesOnlyForLocalModels() async throws {
        let hosted = try await Fixture(files: ["a.txt": "    value\n"])
        await hosted.read("a.txt")
        let refused = await hosted.patch("--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-        value\n+        VALUE\n")
        #expect(refused.isError)
        #expect(hosted.disk("a.txt") == "    value\n")

        let local = try await Fixture(files: ["a.txt": "    value\n"])
        await local.read("a.txt")
        let applied = await local.patch(
            "--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-        value\n+        VALUE\n", tolerance: .local)
        #expect(!applied.isError)
        #expect(applied.text.contains("shifting indentation"))
        #expect(local.disk("a.txt") == "    VALUE\n")
    }

    @Test func theThirdFailureSuggestsWriteFile() async throws {
        let f = try await Fixture(files: ["a.txt": "alpha\n"])
        await f.read("a.txt")
        let failures = EditFailureLog()
        let patch = "--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-missing\n+nope\n"
        var last = ToolOutput("")
        for _ in 0..<3 { last = await f.patch(patch, failures: failures) }
        #expect(last.isError)
        #expect(last.text.contains("write_file"))
    }
}

/// Fails the write to one path, to exercise the rollback.
private struct FailingWriteWorkspace: AgentWorkspace {
    let base: DiskAgentWorkspace
    let failOnPath: String
    var rootPath: String { base.rootPath }
    func readText(path: String) async throws -> String { try await base.readText(path: path) }
    func listDirectory(path: String) async throws -> [DirectoryEntry] { try await base.listDirectory(path: path) }
    func allFiles() async throws -> [String] { try await base.allFiles() }
    func search(_ query: SearchQuery) async throws -> SearchResults { try await base.search(query) }
    func checkWritable(path: String) throws { try base.checkWritable(path: path) }
    func replaceText(path: String, expecting: String, edits: [AgentTextEdit]) async throws {
        if path == failOnPath { throw AgentWorkspaceError.writeFailed(path: path, reason: "disk full") }
        try await base.replaceText(path: path, expecting: expecting, edits: edits)
    }
    func createFile(path: String, contents: String) async throws { try await base.createFile(path: path, contents: contents) }
    func trashFile(path: String) async throws { try await base.trashFile(path: path) }
}
