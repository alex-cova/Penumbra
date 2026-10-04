import Foundation
import Testing
@testable import AgentKit

private func run(_ tool: any AgentTool, _ arguments: String, in project: TempProject, ledger: ReadLedger = ReadLedger()) async -> ToolOutput {
    await tool.execute(
        argumentsJSON: arguments,
        context: ToolContext(workspace: project.workspace, ledger: ledger, callID: "call"))
}

@Suite struct ReadFileToolTests {
    @Test func numbersLinesAndReportsTheRange() async throws {
        let project = try TempProject(files: ["A.txt": "one\ntwo\nthree\n"])
        let output = await run(ReadFileTool(), #"{"path":"A.txt"}"#, in: project)
        #expect(output.text == "[A.txt: lines 1–3 of 3]\n     1\tone\n     2\ttwo\n     3\tthree\n")
        #expect(!output.isError)
    }

    @Test func pagesWithOffsetAndLimitAndSaysHowToContinue() async throws {
        let text = (1...10).map { "line \($0)" }.joined(separator: "\n")
        let project = try TempProject(files: ["A.txt": text])
        let first = await run(ReadFileTool(), #"{"path":"A.txt","limit":4}"#, in: project)
        #expect(first.text.hasPrefix("[A.txt: lines 1–4 of 10]"))
        #expect(first.text.hasSuffix("[6 more lines. Use offset=5 to continue.]"))
        let second = await run(ReadFileTool(), #"{"path":"A.txt","offset":9,"limit":null}"#, in: project)
        #expect(second.text.contains("     9\tline 9") && second.text.contains("    10\tline 10"))
        #expect(!second.text.contains("more lines"))
    }

    @Test func capsLongFilesAtTheLineLimit() async throws {
        let project = try TempProject(files: ["Big.txt": (1...2_500).map { "l\($0)" }.joined(separator: "\n")])
        let output = await run(ReadFileTool(), #"{"path":"Big.txt"}"#, in: project)
        #expect(output.text.hasPrefix("[Big.txt: lines 1–2000 of 2500]"))
        #expect(output.text.hasSuffix("[500 more lines. Use offset=2001 to continue.]"))
    }

    @Test func capsLongFilesAtTheByteLimit() async throws {
        let line = String(repeating: "x", count: 1_000)
        let project = try TempProject(files: ["Wide.txt": Array(repeating: line, count: 200).joined(separator: "\n")])
        let output = await run(ReadFileTool(), #"{"path":"Wide.txt"}"#, in: project)
        #expect(output.text.utf8.count < ReadFileTool.maxBytes + 1_000)
        #expect(output.text.contains("more lines. Use offset="))
    }

    @Test func truncatesOverlongLinesAndHandlesCRLF() async throws {
        let project = try TempProject(files: ["A.txt": "short\r\n" + String(repeating: "y", count: 3_000) + "\r\n"])
        let output = await run(ReadFileTool(), #"{"path":"A.txt"}"#, in: project)
        #expect(output.text.contains("     1\tshort\n"))
        #expect(output.text.contains("…[line truncated]"))
        #expect(!output.text.contains("\r"))
    }

    @Test func reportsEmptyFilesAndBadOffsets() async throws {
        let project = try TempProject(files: ["Empty.txt": "", "A.txt": "one\n"])
        #expect(await run(ReadFileTool(), #"{"path":"Empty.txt"}"#, in: project).text == "[Empty.txt: empty file]")
        let past = await run(ReadFileTool(), #"{"path":"A.txt","offset":5}"#, in: project)
        #expect(past.isError && past.text.contains("has 1 lines"))
    }

    @Test func failuresAreOutputsTheModelCanActOn() async throws {
        let project = try TempProject()
        let missing = await run(ReadFileTool(), #"{"path":"Nope.java"}"#, in: project)
        #expect(missing == .error("Nope.java does not exist."))
        #expect(await run(ReadFileTool(), #"{"path":"../x"}"#, in: project).isError)
        #expect(await run(ReadFileTool(), #"{}"#, in: project) == .error("Missing required argument \"path\"."))
        #expect(await run(ReadFileTool(), #"{"path":3}"#, in: project) == .error("Argument \"path\" must be a string."))
        #expect(await run(ReadFileTool(), "not json", in: project) == .error("The arguments were not a valid JSON object."))
    }

    @Test func recordsWhatTheModelSaw() async throws {
        let project = try TempProject(files: ["A.txt": "one\n"])
        let ledger = ReadLedger()
        _ = await run(ReadFileTool(), #"{"path":"A.txt"}"#, in: project, ledger: ledger)
        #expect(await ledger.hasRead("A.txt"))
        #expect(await ledger.isCurrent(path: "A.txt", text: "one\n"))
        #expect(await !ledger.isCurrent(path: "A.txt", text: "two\n"))
        #expect(await !ledger.hasRead("B.txt"))
    }
}

@Suite struct SearchToolTests {
    private let files = [
        "src/main/A.java": "class A {\n  void run() {}\n}\n",
        "src/test/ATest.java": "class ATest { void run() {} }\n",
        "README.md": "# Readme\n",
    ]

    @Test func listDirMarksFolders() async throws {
        let project = try TempProject(files: files)
        #expect(await run(ListDirTool(), "{}", in: project).text == "src/\nREADME.md")
        #expect(await run(ListDirTool(), #"{"path":"src/main"}"#, in: project).text == "A.java")
        #expect(await run(ListDirTool(), #"{"path":"."}"#, in: project).text == "src/\nREADME.md")
        #expect(await run(ListDirTool(), #"{"path":"README.md"}"#, in: project) == .error("README.md is not a directory."))
    }

    @Test func globListsMatchesOrSaysThereAreNone() async throws {
        let project = try TempProject(files: files)
        #expect(await run(GlobTool(), #"{"pattern":"**/*Test.java"}"#, in: project).text == "src/test/ATest.java")
        #expect(await run(GlobTool(), #"{"pattern":"*.kt"}"#, in: project).text == "No files match *.kt.")
        #expect(await run(GlobTool(), #"{"pattern":"*.{java"}"#, in: project).isError)
    }

    @Test func globCapsItsResults() async throws {
        let project = try TempProject(files: Dictionary(uniqueKeysWithValues: (0..<250).map { ("f\($0).txt", "x") }))
        let output = await run(GlobTool(), #"{"pattern":"*.txt"}"#, in: project)
        #expect(output.text.hasSuffix("[50 more files not shown. Narrow the pattern.]"))
    }

    @Test func grepPrintsPathLineText() async throws {
        let project = try TempProject(files: files)
        let output = await run(GrepTool(), #"{"pattern":"void run","glob":"*.java"}"#, in: project)
        #expect(output.text == "src/main/A.java:2: void run() {}\nsrc/test/ATest.java:1: class ATest { void run() {} }")
        #expect(await run(GrepTool(), #"{"pattern":"zzz"}"#, in: project).text == "No matches for zzz.")
        #expect(await run(GrepTool(), #"{"pattern":"RUN","case_sensitive":false,"path":"src/main"}"#, in: project).text
            == "src/main/A.java:2: void run() {}")
        #expect(await run(GrepTool(), #"{"pattern":"("}"#, in: project).isError)
    }

    @Test func grepTruncatesLongLinesAndFlagsMoreMatches() async throws {
        let project = try TempProject(files: [
            "Long.txt": "needle " + String(repeating: "z", count: 1_000),
            "Many.txt": Array(repeating: "needle", count: 150).joined(separator: "\n"),
        ])
        let output = await run(GrepTool(), #"{"pattern":"needle"}"#, in: project)
        #expect(output.text.contains("Long.txt:1: needle zzz"))
        #expect(output.text.contains("…"))
        #expect(output.text.hasSuffix("[More matches exist. Narrow the pattern, path or glob.]"))
    }

    @Test func definitionsRenderStrictSchemasWithEveryPropertyRequired() {
        for tool in ReadOnlyTools.all() {
            let schema = tool.definition.schema(strict: true)
            let properties = schema["properties"]?.objectValue ?? [:]
            #expect(Set(schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []) == Set(properties.keys), "\(tool.name)")
            #expect(tool.risk == .read)
        }
        #expect(ReadOnlyTools.all().map(\.name) == ["read_file", "list_dir", "glob", "grep"])
    }
}
