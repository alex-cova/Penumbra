import AgentKit
import EditorIntelligence
import JavaIntelligence
import Foundation
import XCTest
@testable import Umbra

final class IDEAgentSymbolLocatorTests: XCTestCase {
    private let source = "class A {\n  int count = 0;\n  void add(int count) { this.count += count; }\r\n  void count() {}\n}\n"

    func testFindsTheOnlyWholeWordMatchAndIgnoresLongerIdentifiers() throws {
        let offset = try IDEAgentSymbolLocator.offset(in: source, line: 2, symbol: "count")
        XCTAssertEqual((source as NSString).substring(with: NSRange(location: offset, length: 5)), "count")
        XCTAssertEqual(offset, 16)
        // "counter" must not match "count".
        XCTAssertThrowsError(try IDEAgentSymbolLocator.offset(in: "int counter;", line: 1, symbol: "count")) {
            guard case .notOnLine = $0 as? IDEAgentSymbolLocator.Failure else { return XCTFail("\($0)") }
        }
    }

    func testSeveralMatchesNeedAnOccurrenceAndCRLFLinesCountOnce() throws {
        XCTAssertThrowsError(try IDEAgentSymbolLocator.offset(in: source, line: 3, symbol: "count")) {
            XCTAssertEqual($0 as? IDEAgentSymbolLocator.Failure, .ambiguous(symbol: "count", line: 3, count: 3))
        }
        let third = try IDEAgentSymbolLocator.offset(in: source, line: 3, symbol: "count", occurrence: 3)
        XCTAssertEqual((source as NSString).substring(with: NSRange(location: third - 3, length: 8)), "+= count", "the third `count` on the CRLF line")
        XCTAssertThrowsError(try IDEAgentSymbolLocator.offset(in: source, line: 3, symbol: "count", occurrence: 4))
        // The line after a CRLF line is line 4, not 5.
        let method = try IDEAgentSymbolLocator.offset(in: source, line: 4, symbol: "count")
        XCTAssertEqual((source as NSString).substring(with: NSRange(location: method - 5, length: 10)), "void count")
    }

    func testLinesOutsideTheFileAreRefusedWithItsLength() {
        XCTAssertThrowsError(try IDEAgentSymbolLocator.offset(in: source, line: 0, symbol: "A")) {
            XCTAssertEqual($0 as? IDEAgentSymbolLocator.Failure, .lineOutOfRange(line: 0, lineCount: 5))
        }
        XCTAssertThrowsError(try IDEAgentSymbolLocator.offset(in: source, line: 6, symbol: "A")) {
            XCTAssertEqual($0 as? IDEAgentSymbolLocator.Failure, .lineOutOfRange(line: 6, lineCount: 5), "a trailing newline starts no line")
        }
        XCTAssertEqual(try IDEAgentSymbolLocator.offset(in: "x", line: 1, symbol: "x"), 0)
    }

    func testDollarsUnderscoresAndNonASCIIIdentifiersAreWholeWords() throws {
        XCTAssertEqual(try IDEAgentSymbolLocator.offset(in: "a $x _x x\n", line: 1, symbol: "x"), 8)
        XCTAssertThrowsError(try IDEAgentSymbolLocator.offset(in: "var é1 = 1;", line: 1, symbol: "é"))
        XCTAssertEqual(try IDEAgentSymbolLocator.offset(in: "var 😀 = é;", line: 1, symbol: "é"), 9, "UTF-16 offsets, the emoji is two units")
    }
}

private struct FakeNavigator: IDEAgentJavaNavigating {
    var definition: [IDEAgentCodeLocation] = []
    var usage: [IDEAgentCodeLocation] = []
    var seen: LockedBox = LockedBox()

    final class LockedBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [Int] = []
        func add(_ offset: Int) { lock.lock(); value.append(offset); lock.unlock() }
        var offsets: [Int] { lock.lock(); defer { lock.unlock() }; return value }
    }

    func definitions(file: URL, source: String, utf16Offset: Int) async -> [IDEAgentCodeLocation] {
        seen.add(utf16Offset)
        return definition
    }

    func usages(file: URL, source: String, utf16Offset: Int) async -> [IDEAgentCodeLocation] {
        seen.add(utf16Offset)
        return usage
    }
}

final class IDEAgentNavigationToolTests: XCTestCase {
    private var project: URL!

    override func setUpWithError() throws {
        project = FileManager.default.temporaryDirectory.appendingPathComponent("agent-nav-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "class A {\n  int total = 0;\n  int get() { return total; }\n}\n".write(
            to: project.appendingPathComponent("src/A.java"), atomically: true, encoding: .utf8)
        try "notes".write(to: project.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: project) }

    private func run(_ tool: any AgentTool, _ json: String) async -> ToolOutput {
        await tool.execute(
            argumentsJSON: json, context: ToolContext(workspace: DiskAgentWorkspace(root: project), ledger: ReadLedger(), callID: "c"))
    }

    private let lineText: @Sendable (URL, Int) async -> String? = { url, line in
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\n")
        return line >= 1 && line <= lines.count ? lines[line - 1] : nil
    }

    func testUsagesAreListedAsPathLineTextWithKindsAndAmbiguityAndTheCallerNeverCountsColumns() async throws {
        let file = project.appendingPathComponent("src/A.java")
        let navigator = FakeNavigator(usage: [
            IDEAgentCodeLocation(fileURL: file, line: 3, label: "", kind: "read"),
            IDEAgentCodeLocation(fileURL: file, line: 2, label: "", kind: "write", isAmbiguous: true),
        ])
        let output = await run(IDEFindUsagesTool(navigator: navigator, lineText: lineText), #"{"path":"src/A.java","line":2,"symbol":"total"}"#)
        XCTAssertFalse(output.isError, output.text)
        XCTAssertEqual(output.text, """
        2 usages:
        src/A.java:3: int get() { return total; }  [read]
        src/A.java:2: int total = 0;  [write]  (may belong to an overload or sibling)
        """)
        XCTAssertEqual(navigator.seen.offsets, [16], "the offset of `total` on line 2")
    }

    func testDefinitionsOutsideTheProjectAreNamedNotOpened() async {
        let navigator = FakeNavigator(definition: [
            IDEAgentCodeLocation(fileURL: URL(fileURLWithPath: "/Library/Java/jdk/src/java.base/java/util/List.java"), line: 10, label: "List"),
            IDEAgentCodeLocation(fileURL: nil, line: 1, label: "com.acme.Widget"),
        ])
        let output = await run(IDEGoToDefinitionTool(navigator: navigator, lineText: lineText), #"{"path":"src/A.java","line":3,"symbol":"total"}"#)
        XCTAssertEqual(output.text, "(outside the project) List\n(library) com.acme.Widget")
        XCTAssertFalse(output.text.contains("/Library"), "no absolute path outside the project is shown")
    }

    func testBadInputsGetErrorsTheModelCanActOn() async {
        let tool = IDEFindUsagesTool(navigator: FakeNavigator(), lineText: lineText)
        let notJava = await run(tool, #"{"path":"README.md","line":1,"symbol":"notes"}"#)
        XCTAssertTrue(notJava.isError && notJava.text.contains("not one"))
        let wrongSymbol = await run(tool, #"{"path":"src/A.java","line":2,"symbol":"missing"}"#)
        XCTAssertTrue(wrongSymbol.isError && wrongSymbol.text.contains("does not appear as a whole word on line 2"))
        let beyond = await run(tool, #"{"path":"src/A.java","line":99,"symbol":"total"}"#)
        XCTAssertTrue(beyond.isError && beyond.text.contains("4 lines"))
        let escape = await run(tool, #"{"path":"../x.java","line":1,"symbol":"x"}"#)
        XCTAssertTrue(escape.isError, "the path jail applies")
        let noLine = await run(tool, #"{"path":"src/A.java","symbol":"total"}"#)
        XCTAssertTrue(noLine.isError && noLine.text.contains("Missing `line`"))
        let none = await run(tool, #"{"path":"src/A.java","line":2,"symbol":"total"}"#)
        XCTAssertFalse(none.isError)
        XCTAssertTrue(none.text.hasPrefix("No usages found."))
    }

    func testLongResultListsAreCapped() async {
        let file = project.appendingPathComponent("src/A.java")
        let many = (0..<150).map { _ in IDEAgentCodeLocation(fileURL: file, line: 2, label: "") }
        let output = await run(IDEFindUsagesTool(navigator: FakeNavigator(usage: many), lineText: lineText), #"{"path":"src/A.java","line":2,"symbol":"total"}"#)
        XCTAssertTrue(output.text.hasPrefix("150 usages:"))
        XCTAssertTrue(output.text.hasSuffix("… and 50 more."))
    }
}

final class IDEAgentGitToolTests: XCTestCase {
    private var repo: URL!

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory.appendingPathComponent("agent-git-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main")
        try git("config", "user.email", "t@example.com")
        try git("config", "user.name", "T")
        try git("config", "commit.gpgsign", "false")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: repo) }

    @discardableResult
    private func git(_ arguments: String..., in directory: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory ?? repo
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: data, as: UTF8.self))
        return String(decoding: data, as: UTF8.self)
    }

    private func write(_ path: String, _ text: String) throws {
        let url = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func source(root: URL? = nil, patterns: [String] = [], unsaved: [String: String] = [:]) -> IDEAgentGitSource {
        IDEAgentGitSource(
            projectRoot: root ?? repo, secretPatterns: SecretFilePolicy.patterns(from: patterns), unsavedBuffers: { unsaved })
    }

    private func run(_ tool: any AgentTool, _ json: String = "{}") async -> ToolOutput {
        await tool.execute(
            argumentsJSON: json, context: ToolContext(workspace: DiskAgentWorkspace(root: repo), ledger: ReadLedger(), callID: "c"))
    }

    private func commitBase() throws {
        try write("A.txt", "one\ntwo\n")
        try write("B.txt", "b\n")
        try git("add", "-A")
        try git("commit", "-q", "-m", "base")
    }

    func testStatusNamesTheBranchAndEveryKindOfChange() async throws {
        try commitBase()
        try write("A.txt", "one\n2\n")
        try write("C.txt", "new\n")
        try git("add", "B.txt")
        try "b2\n".write(to: repo.appendingPathComponent("B.txt"), atomically: true, encoding: .utf8)
        try git("add", "B.txt")

        let output = await run(IDEGitStatusTool(source: source()))
        XCTAssertFalse(output.isError, output.text)
        XCTAssertTrue(output.text.hasPrefix("Branch: main\n"))
        XCTAssertTrue(output.text.contains(" M A.txt"))
        XCTAssertTrue(output.text.contains("M  B.txt"))
        XCTAssertTrue(output.text.contains("?? C.txt"))
    }

    func testACleanTreeSaysSoAndANonRepositoryIsExplained() async throws {
        try commitBase()
        let clean = await run(IDEGitStatusTool(source: source()))
        XCTAssertEqual(clean.text, "Branch: main\nWorking tree clean.")

        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-repo-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let output = await run(IDEGitStatusTool(source: source(root: elsewhere)))
        XCTAssertTrue(output.isError)
        XCTAssertTrue(output.text.contains("not inside a git repository"))
    }

    func testDiffShowsWorkingTreeAgainstHeadIncludingNewFilesAndSelectsByPath() async throws {
        try commitBase()
        try write("A.txt", "one\n2\n")
        try write("C.txt", "new\n")
        let all = await run(IDEGitDiffTool(source: source()))
        XCTAssertTrue(all.text.contains("-two") && all.text.contains("+2"), all.text)
        XCTAssertTrue(all.text.contains("+++ b/C.txt") && all.text.contains("+new"), "an untracked file reads as new")

        let one = await run(IDEGitDiffTool(source: source()), #"{"path":"A.txt"}"#)
        XCTAssertTrue(one.text.contains("A.txt") && !one.text.contains("C.txt"))
        let none = await run(IDEGitDiffTool(source: source()), #"{"path":"B.txt"}"#)
        XCTAssertEqual(none.text, "No changes in B.txt.")
    }

    func testStagedShowsOnlyWhatIsStaged() async throws {
        try commitBase()
        try write("A.txt", "one\nstaged\n")
        try git("add", "A.txt")
        try write("B.txt", "unstaged\n")
        let staged = await run(IDEGitDiffTool(source: source()), #"{"staged":true}"#)
        XCTAssertTrue(staged.text.contains("+staged") && !staged.text.contains("unstaged"), staged.text)
        try git("reset", "-q")
        let nothing = await run(IDEGitDiffTool(source: source()), #"{"staged":true}"#)
        XCTAssertEqual(nothing.text, "Nothing is staged.")
    }

    func testCredentialFilesNeverReachTheModelThroughADiff() async throws {
        try commitBase()
        try write(".env", "API_KEY=hunter2\n")
        try write("config/prod.vault", "token=hunter2\n")
        try write("A.txt", "one\nchanged\n")
        let output = await run(IDEGitDiffTool(source: source(patterns: ["*.vault"])))
        XCTAssertFalse(output.text.contains("hunter2"), output.text)
        XCTAssertTrue(output.text.contains("+changed"))
        XCTAssertTrue(output.text.contains("Not shown, credential files:") && output.text.contains(".env") && output.text.contains("prod.vault"))

        let direct = await run(IDEGitDiffTool(source: source()), #"{"path":".env"}"#)
        XCTAssertTrue(direct.isError && !direct.text.contains("hunter2"))
        let tracked = await run(IDEGitDiffTool(source: source(patterns: ["*.vault"])), #"{"path":"config/prod.vault"}"#)
        XCTAssertTrue(tracked.isError)
    }

    func testNewFilesInAnUntrackedFolderAreShownOneByOne() async throws {
        try commitBase()
        try write("newdir/Ok.txt", "visible line\n")
        try write("newdir/.env", "API_KEY=hunter2\n")
        let output = await run(IDEGitDiffTool(source: source()))
        XCTAssertTrue(output.text.contains("+++ b/newdir/Ok.txt") && output.text.contains("+visible line"), output.text)
        XCTAssertFalse(output.text.contains("hunter2"))
        XCTAssertTrue(output.text.contains("Not shown, credential files: newdir/.env"), output.text)
    }

    func testBigDiffsAreCutAndUnsavedBuffersAreNamed() async throws {
        try commitBase()
        for index in 0..<10 { try write("big\(index).txt", String(repeating: "line of text\n", count: 2_000)) }
        let big = await run(IDEGitDiffTool(source: source(unsaved: [repo.appendingPathComponent("A.txt").path: "x"])))
        XCTAssertLessThan(big.text.count, IDEGitDiffTool.maxTotalCharacters + 4 * IDEGitDiffTool.maxFileCharacters)
        XCTAssertTrue(big.text.contains("not shown: ask for one with `path`"), "later files are listed as omitted")
        XCTAssertTrue(big.text.contains("earlier output") || big.text.contains("left out") || big.text.contains("omitted"), "a cut file says so")

        try write("A.txt", "one\nedited on disk\n")
        let named = await run(IDEGitDiffTool(source: source(unsaved: [repo.appendingPathComponent("A.txt").path: "x"])), #"{"path":"A.txt"}"#)
        XCTAssertTrue(named.text.contains("Unsaved edits in the editor are not part of this diff: A.txt"), named.text)
    }

    func testAProjectInsideALargerRepositoryOnlySeesItsOwnFiles() async throws {
        try write("app/A.txt", "one\n")
        try write("other/B.txt", "b\n")
        try git("add", "-A")
        try git("commit", "-q", "-m", "base")
        try write("app/A.txt", "one\nmore\n")
        try write("other/B.txt", "b\nsecret change elsewhere\n")
        let app = repo.appendingPathComponent("app")
        let status = await run(IDEGitStatusTool(source: source(root: app)))
        XCTAssertTrue(status.text.contains(" M A.txt") && !status.text.contains("B.txt"), status.text)
        let diff = await run(IDEGitDiffTool(source: source(root: app)))
        XCTAssertTrue(diff.text.contains("+more"))
        XCTAssertFalse(diff.text.contains("elsewhere"), "files outside the project folder stay out")
    }
}

/// The tools on top of the real Java providers, over a small indexed project.
final class IDEAgentJavaNavigationIntegrationTests: XCTestCase {
    private func makeTools() async throws -> (JavaReferenceFixture, IDEGoToDefinitionTool, IDEFindUsagesTool) {
        let fixture = try JavaReferenceFixture()
        try fixture.add("src/Calc.java", """
        package demo;

        public class Calc {
            public int add(int a, int b) {
                return a + b;
            }

            public int add(int a, int b, int c) {
                return add(add(a, b), c);
            }
        }

        """)
        try fixture.add("src/Main.java", """
        package demo;

        public class Main {
            public static void main(String[] args) {
                Calc calc = new Calc();
                System.out.println(calc.add(1, 2));
            }
        }

        """)
        let environment = try await fixture.build()
        let paths = JavaIndexPaths(root: fixture.root.appendingPathComponent("cache"))
        let definitions = JavaGoToDefinitionProvider(index: environment.index, indexPaths: paths)
        let usages = JavaFindUsagesProvider(index: environment.index, indexPaths: paths)
        await usages.setProjectRoots([fixture.root])
        let navigator = IDEJavaAgentNavigator(definitionProvider: definitions, usageProvider: usages)
        let lineText: @Sendable (URL, Int) async -> String? = { url, line in
            let lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").components(separatedBy: "\n")
            return line >= 1 && line <= lines.count ? lines[line - 1] : nil
        }
        return (fixture, IDEGoToDefinitionTool(navigator: navigator, lineText: lineText), IDEFindUsagesTool(navigator: navigator, lineText: lineText))
    }

    private func run(_ tool: any AgentTool, _ fixture: JavaReferenceFixture, _ json: String) async -> ToolOutput {
        await tool.execute(
            argumentsJSON: json, context: ToolContext(workspace: DiskAgentWorkspace(root: fixture.root), ledger: ReadLedger(), callID: "c"))
    }

    func testGoToDefinitionResolvesTheCalledOverloadAcrossFiles() async throws {
        let (fixture, definition, _) = try await makeTools()
        let output = await run(definition, fixture, #"{"path":"src/Main.java","line":6,"symbol":"add"}"#)
        XCTAssertFalse(output.isError, output.text)
        XCTAssertEqual(output.text, "src/Calc.java:4: public int add(int a, int b) {", "the two-argument overload, not the three-argument one")

        let type = await run(definition, fixture, #"{"path":"src/Main.java","line":5,"symbol":"Calc","occurrence":2}"#)
        XCTAssertTrue(type.text.contains("src/Calc.java:"), type.text)
    }

    func testFindUsagesListsCallsInBothFilesAndNotTheOtherOverload() async throws {
        let (fixture, _, usages) = try await makeTools()
        let output = await run(usages, fixture, #"{"path":"src/Calc.java","line":4,"symbol":"add"}"#)
        XCTAssertFalse(output.isError, output.text)
        XCTAssertTrue(output.text.contains("src/Main.java:6:"), output.text)
        XCTAssertTrue(output.text.contains("src/Calc.java:9:"), "the inner add(a, b) call")
        XCTAssertFalse(output.text.contains("public int add(int a, int b, int c)"), "declarations are not usages")
    }

    func testAnUnknownSymbolSaysWhyThereIsNoAnswer() async throws {
        let (fixture, definition, _) = try await makeTools()
        let output = await run(definition, fixture, #"{"path":"src/Main.java","line":6,"symbol":"println"}"#)
        XCTAssertFalse(output.isError, output.text)
        XCTAssertEqual(
            output.text, "No definition found. The symbol may be unresolved (check `diagnostics`), or the index is still building.",
            "println is in the JDK, which this fixture does not index")
    }
}

private struct FakeHoverProvider: HoverProvider {
    let name = "fake"
    var result: HoverResult?
    func provide(context: HoverContext) async -> HoverResult? { result }
}

final class IDEHoverToolTests: XCTestCase {
    private var project: URL!

    override func setUpWithError() throws {
        project = FileManager.default.temporaryDirectory.appendingPathComponent("agent-hover-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "class A {\n  int total = 0;\n}\n".write(
            to: project.appendingPathComponent("src/A.java"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: project) }

    private func run(_ tool: IDEHoverTool, _ json: String) async -> ToolOutput {
        await tool.execute(
            argumentsJSON: json, context: ToolContext(workspace: DiskAgentWorkspace(root: project), ledger: ReadLedger(), callID: "c"))
    }

    func testHoverReturnsTheProviderContents() async {
        let contents = "int total\n\nThe running total."
        let tool = IDEHoverTool(engine: HoverEngine(providers: [FakeHoverProvider(result: HoverResult(contents: contents, source: "fake"))]))
        let output = await run(tool, #"{"path":"src/A.java","line":2,"symbol":"total"}"#)
        XCTAssertFalse(output.isError, output.text)
        XCTAssertEqual(output.text, contents)
    }

    func testHoverWithoutAResultSaysSo() async {
        let tool = IDEHoverTool(engine: HoverEngine(providers: [FakeHoverProvider(result: nil)]))
        let output = await run(tool, #"{"path":"src/A.java","line":2,"symbol":"total"}"#)
        XCTAssertFalse(output.isError)
        XCTAssertTrue(output.text.contains("No documentation found"), output.text)
    }

    func testLongHoverContentsAreClipped() async {
        let contents = String(repeating: "x", count: IDEHoverTool.maxContentsLength + 100)
        let tool = IDEHoverTool(engine: HoverEngine(providers: [FakeHoverProvider(result: HoverResult(contents: contents, source: "fake"))]))
        let output = await run(tool, #"{"path":"src/A.java","line":2,"symbol":"total"}"#)
        XCTAssertFalse(output.isError)
        XCTAssertTrue(output.text.hasSuffix("…"), "long hover cards are clipped")
        XCTAssertLessThan(output.text.count, contents.count)
    }
}

private struct FakeRenamer: RenameProviding {
    var target: RenameTarget?
    var plan = RenamePlan()
    var failure: String?
    func prepareRename(_ context: NavigationContext) async -> RenameTarget? { target }
    func rename(_ context: NavigationContext, to newName: String) async throws -> RenamePlan {
        if let failure { throw ToolError(failure) }
        return plan
    }
}

final class IDERenameSymbolToolTests: XCTestCase {
    private var project: URL!
    private let aSource = "class A {\n  int total = 0;\n  int get() { return total; }\n}\n"
    private let bSource = "class B {\n  int sum = A.total;\n}\n"

    override func setUpWithError() throws {
        project = FileManager.default.temporaryDirectory.appendingPathComponent("agent-rename-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
        try aSource.write(to: project.appendingPathComponent("src/A.java"), atomically: true, encoding: .utf8)
        try bSource.write(to: project.appendingPathComponent("src/B.java"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: project) }

    private func entry(file: String, line: Int, old: String, new: String, ambiguous: Bool = false) throws -> WorkspaceEditPlanEntry {
        let source = try String(contentsOf: project.appendingPathComponent(file), encoding: .utf8)
        let offset = try IDEAgentSymbolLocator.offset(in: source, line: line, symbol: old)
        let index = IDEAgentLineIndex(source)
        let start = TextPosition(line: line - 1, column: offset - index.start(ofLine: line), utf16Offset: offset)
        let lines = source.components(separatedBy: "\n")
        return WorkspaceEditPlanEntry(
            url: project.appendingPathComponent(file),
            range: TextRange(start: start, end: TextPosition(line: line - 1, column: start.column + old.count, utf16Offset: offset + old.count)),
            oldText: old, newText: new, lineText: lines[line - 1], isAmbiguous: ambiguous)
    }

    private func target() throws -> RenameTarget {
        let offset = try IDEAgentSymbolLocator.offset(in: aSource, line: 2, symbol: "total")
        let position = TextPosition(line: 1, column: 6, utf16Offset: offset)
        return RenameTarget(range: TextRange(start: position, end: position), currentName: "total", kindDescription: "field")
    }

    private func tool(plan: RenamePlan, target: RenameTarget? = nil, providesTarget: Bool = true, failure: String? = nil) throws -> IDERenameSymbolTool {
        IDERenameSymbolTool(
            renamer: FakeRenamer(
                target: providesTarget ? (try target ?? self.target()) : nil, plan: plan, failure: failure),
            lineText: { [project] url, line in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let lines = text.components(separatedBy: "\n")
                return line >= 1 && line <= lines.count ? lines[line - 1] : nil
            })
    }

    private func makeContext(log: CheckpointLog? = nil) async -> (ToolContext, DiskAgentWorkspace) {
        let workspace = DiskAgentWorkspace(root: project)
        var scope: CheckpointScope?
        if let log { scope = CheckpointScope(log: log, run: await log.beginRun(label: "test")) }
        return (ToolContext(workspace: workspace, ledger: ReadLedger(), callID: "c", checkpoint: scope), workspace)
    }

    private func contents(_ path: String) throws -> String {
        try String(contentsOf: project.appendingPathComponent(path), encoding: .utf8)
    }

    func testRenameAcrossFilesAppliesCheckpointedEditsAndRevertRestoresThem() async throws {
        let plan = RenamePlan(entries: [
            try entry(file: "src/A.java", line: 2, old: "total", new: "sum"),
            try entry(file: "src/A.java", line: 3, old: "total", new: "sum"),
            try entry(file: "src/B.java", line: 2, old: "total", new: "sum"),
        ])
        let log = CheckpointLog()
        let (context, workspace) = await makeContext(log: log)
        let output = await (try tool(plan: plan)).execute(
            argumentsJSON: #"{"path":"src/A.java","line":2,"symbol":"total","newName":"sum"}"#, context: context)
        XCTAssertFalse(output.isError, output.text)
        XCTAssertTrue(output.text.hasPrefix("Renamed “total” to “sum”: 3 occurrences in 2 files"), output.text)
        XCTAssertTrue(output.text.contains("src/A.java:2:"), output.text)
        XCTAssertTrue(output.text.contains("src/B.java:2:"), output.text)
        XCTAssertTrue(try contents("src/A.java").contains("int sum = 0;"))
        XCTAssertTrue(try contents("src/A.java").contains("return sum;"))
        XCTAssertTrue(try contents("src/B.java").contains("A.sum;"))

        let runs = await log.runs
        let run = try XCTUnwrap(runs.first?.id, "the rename was checkpointed")
        _ = await log.revert(run, using: workspace, ledger: ReadLedger())
        XCTAssertEqual(try contents("src/A.java"), aSource, "Revert Run restores the rename")
        XCTAssertEqual(try contents("src/B.java"), bSource)
    }

    func testRenameRefusedWhenNothingIsRenamable() async throws {
        let (context, _) = await makeContext()
        let output = await (try tool(plan: RenamePlan(), providesTarget: false)).execute(
            argumentsJSON: #"{"path":"src/A.java","line":2,"symbol":"total","newName":"sum"}"#, context: context)
        XCTAssertFalse(output.isError)
        XCTAssertTrue(output.text.contains("cannot be renamed"), output.text)
        XCTAssertEqual(try contents("src/A.java"), aSource, "nothing changed")
    }

    func testRenameToTheSameNameIsANoOp() async throws {
        let (context, _) = await makeContext()
        let output = await (try tool(plan: RenamePlan())).execute(
            argumentsJSON: #"{"path":"src/A.java","line":2,"symbol":"total","newName":"total"}"#, context: context)
        XCTAssertFalse(output.isError)
        XCTAssertTrue(output.text.contains("already named"), output.text)
        XCTAssertEqual(try contents("src/A.java"), aSource)
    }

    func testInvalidNewNameIsAnError() async throws {
        let (context, _) = await makeContext()
        let output = await (try tool(plan: RenamePlan())).execute(
            argumentsJSON: #"{"path":"src/A.java","line":2,"symbol":"total","newName":"9bad"}"#, context: context)
        XCTAssertTrue(output.isError, "an invalid name fails instead of renaming")
        XCTAssertEqual(try contents("src/A.java"), aSource)
    }

    func testBlockedPlanIsAnError() async throws {
        let (context, _) = await makeContext()
        let output = await (try tool(plan: RenamePlan(blockingError: "total is not visible here"))).execute(
            argumentsJSON: #"{"path":"src/A.java","line":2,"symbol":"total","newName":"sum"}"#, context: context)
        XCTAssertTrue(output.isError)
        XCTAssertTrue(output.text.contains("not visible"), output.text)
        XCTAssertEqual(try contents("src/A.java"), aSource)
    }

    func testOutsideProjectEntriesAreSkipped() async throws {
        let outside = URL(fileURLWithPath: "/elsewhere/F.java")
        let plan = RenamePlan(entries: [
            try entry(file: "src/A.java", line: 2, old: "total", new: "sym"),
            WorkspaceEditPlanEntry(
                url: outside, range: TextRange(
                    start: TextPosition(line: 0, column: 0, utf16Offset: 0),
                    end: TextPosition(line: 0, column: 5, utf16Offset: 5)),
                oldText: "total", newText: "sym", lineText: "total"),
        ])
        let (context, _) = await makeContext()
        let output = await (try tool(plan: plan)).execute(
            argumentsJSON: #"{"path":"src/A.java","line":2,"symbol":"total","newName":"sym"}"#, context: context)
        XCTAssertFalse(output.isError, output.text)
        XCTAssertTrue(output.text.contains("1 occurrence in 1 file"), output.text)
        XCTAssertTrue(output.text.contains("outside the project"), output.text)
        XCTAssertTrue(try contents("src/A.java").contains("int sym = 0;"))
    }

    func testAmbiguousOccurrencesAreLeftOutForFindUsages() async throws {
        let plan = RenamePlan(entries: [
            try entry(file: "src/A.java", line: 2, old: "total", new: "sum"),
            try entry(file: "src/A.java", line: 3, old: "total", new: "sum", ambiguous: true),
        ])
        let (context, _) = await makeContext()
        let output = await (try tool(plan: plan)).execute(
            argumentsJSON: #"{"path":"src/A.java","line":2,"symbol":"total","newName":"sum"}"#, context: context)
        XCTAssertFalse(output.isError, output.text)
        XCTAssertTrue(output.text.contains("1 occurrence in 1 file"), output.text)
        XCTAssertTrue(output.text.contains("check it with find_usages"), output.text)
        XCTAssertTrue(try contents("src/A.java").contains("int sum = 0;"))
        XCTAssertTrue(try contents("src/A.java").contains("return total;"), "the ambiguous use is untouched")
    }

    func testPreviewShowsTheDiffWithoutChangingFiles() async throws {
        let plan = RenamePlan(entries: [try entry(file: "src/A.java", line: 2, old: "total", new: "sum")])
        let (context, _) = await makeContext()
        let preview = await (try tool(plan: plan)).editPreview(
            for: try ToolArguments(json: #"{"path":"src/A.java","line":2,"symbol":"total","newName":"sum"}"#), context: context)
        let diff = try XCTUnwrap(preview?.diff)
        XCTAssertTrue(diff.contains("total") && diff.contains("sum"), diff)
        XCTAssertEqual(try contents("src/A.java"), aSource, "a preview changes nothing")
    }
}
