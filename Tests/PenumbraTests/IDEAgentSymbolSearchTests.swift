import AgentKit
import EditorIntelligence
import Foundation
import JavaIntelligence
import XCTest
@testable import Umbra

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var offsets: [Int] = []
    func add(_ offset: Int) { lock.lock(); offsets.append(offset); lock.unlock() }
    var all: [Int] { lock.lock(); defer { lock.unlock() }; return offsets }
}

private struct FakeSearch: IDEAgentSymbolSearching {
    var all: [IDEAgentSymbol] = []
    var status: String?
    var files: [URL: String] = [:]

    func symbols(matching query: String, exactName: Bool, limit: Int) async -> [IDEAgentSymbol] {
        Array(all.filter { !exactName || $0.name == query }.prefix(limit))
    }

    func liveText(of file: URL) async -> String? { files[file] }

    func structure(file: URL, source: String) async -> [StructureNode] {
        await JavaStructureProvider().allStructure(forSource: source) ?? []
    }

    func indexStatus() async -> String? { status }
}

private struct FakeExploreNavigator: IDEAgentNavigating {
    var usage: [IDEAgentCodeLocation] = []
    var implementation: [IDEAgentCodeLocation] = []
    let calls = Calls()

    func definitions(file: URL, source: String, utf16Offset: Int) async -> [IDEAgentCodeLocation] { [] }

    func usages(file: URL, source: String, utf16Offset: Int) async -> [IDEAgentCodeLocation] {
        calls.add(utf16Offset)
        return usage
    }

    func implementations(file: URL, source: String, utf16Offset: Int) async -> [IDEAgentCodeLocation] {
        calls.add(utf16Offset)
        return implementation
    }
}

private let lineText: @Sendable (URL, Int) async -> String? = { url, line in
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    let lines = text.components(separatedBy: "\n")
    return line >= 1 && line <= lines.count ? lines[line - 1] : nil
}

private func runTool(_ tool: any AgentTool, root: URL, _ json: String) async -> ToolOutput {
    await tool.execute(
        argumentsJSON: json, context: ToolContext(workspace: DiskAgentWorkspace(root: root), ledger: ReadLedger(), callID: "c"))
}

final class IDEAgentSymbolToolTests: XCTestCase {
    private var project: URL!
    private var file: URL!
    private let source = """
    package demo;

    /** Adds things. */
    @Deprecated
    public class A {
        int total = 0;
        public int get() { return total; }
    }

    """

    override func setUpWithError() throws {
        project = FileManager.default.temporaryDirectory.appendingPathComponent("agent-sym-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
        file = project.appendingPathComponent("src/A.java")
        try source.write(to: file, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: project) }

    private func offset(of needle: String, skipping prefix: Int = 0) -> Int {
        (source as NSString).range(of: needle).location + prefix
    }

    private func classA(line: Int? = 5, offset: Int? = nil) -> IDEAgentSymbol {
        IDEAgentSymbol(
            name: "A", qualifiedName: "demo.A", kind: "class", isType: true, detail: nil, fileURL: file,
            line: line, utf16Offset: offset ?? self.offset(of: "class A", skipping: 6))
    }

    // MARK: find_symbol

    func testRowsAreGrepShapedAndMarkWhatTheIndexGotWrong() async {
        let method = IDEAgentSymbol(
            name: "get", qualifiedName: "demo.A.get", kind: "method", isType: false, detail: "(): int", fileURL: file, line: 7, utf16Offset: 1)
        var moved = classA()
        moved.movedSinceIndexing = true
        let outside = IDEAgentSymbol(
            name: "Alien", qualifiedName: "x.Alien", kind: "class", isType: true, detail: nil,
            fileURL: URL(fileURLWithPath: "/Library/Java/Alien.java"), line: 3, utf16Offset: 1)
        let gone = IDEAgentSymbol(name: "AGone", qualifiedName: "demo.AGone", kind: "class", isType: true, detail: nil, fileURL: file)
        let tool = IDEFindSymbolTool(search: FakeSearch(all: [method, moved, outside, gone]))
        let output = await runTool(tool, root: project, #"{"query":"a"}"#)
        XCTAssertFalse(output.isError, output.text)
        XCTAssertEqual(output.text.components(separatedBy: "\n"), [
            "src/A.java:7: method demo.A.get(): int",
            "src/A.java:5: class demo.A  (moved since indexing)",
            "(outside the project) class x.Alien",
            "src/A.java: class demo.AGone  (not found where the index put it; the file changed since it was indexed)",
        ])
        XCTAssertFalse(output.text.contains("/Library"), "no absolute path outside the project")
    }

    func testTheLimitCapsRowsAndSaysSo() async {
        let many = (1...30).map {
            IDEAgentSymbol(name: "Item\($0)", qualifiedName: "demo.Item\($0)", kind: "class", isType: true, detail: nil, fileURL: file, line: $0, utf16Offset: 0)
        }
        let tool = IDEFindSymbolTool(search: FakeSearch(all: many))
        let defaulted = await runTool(tool, root: project, #"{"query":"Item"}"#)
        XCTAssertEqual(defaulted.text.components(separatedBy: "\n").count, IDEFindSymbolTool.defaultLimit + 1)
        XCTAssertTrue(defaulted.text.hasSuffix("Use a longer query to narrow it."))
        let huge = await runTool(tool, root: project, #"{"query":"Item","limit":500}"#)
        XCTAssertEqual(huge.text.components(separatedBy: "\n").count, 30, "30 rows, under the cap, so no note")
    }

    func testAnEmptyAnswerDependsOnWhetherTheIndexIsReady() async {
        let building = await runTool(IDEFindSymbolTool(search: FakeSearch(status: "Indexing project sources…")), root: project, #"{"query":"Zed"}"#)
        XCTAssertFalse(building.isError)
        XCTAssertTrue(building.text.contains("still being built") && building.text.contains("grep"), building.text)
        let ready = await runTool(IDEFindSymbolTool(search: FakeSearch()), root: project, #"{"query":"Zed"}"#)
        XCTAssertTrue(ready.text.hasPrefix("No project declaration matches “Zed”"), ready.text)
        let blank = await runTool(IDEFindSymbolTool(search: FakeSearch()), root: project, #"{"query":"  "}"#)
        XCTAssertTrue(blank.isError)
    }

    func testResultsWhileTheIndexBuildsCarryABanner() async {
        let tool = IDEFindSymbolTool(search: FakeSearch(all: [classA()], status: "Indexing dependencies… (3/12)"))
        let output = await runTool(tool, root: project, #"{"query":"A"}"#)
        XCTAssertTrue(output.text.hasPrefix("[The index is still being built (Indexing dependencies… (3/12))."), output.text)
        XCTAssertTrue(output.text.contains("src/A.java:5: class demo.A"))
    }

    // MARK: explore_symbol

    func testSeveralDeclarationsWithOneNameReturnCandidatesAndNeverGuess() async {
        let first = IDEAgentSymbol(name: "add", qualifiedName: "demo.A.add", kind: "method", isType: false, detail: "(int, int): int", fileURL: file, line: 6, utf16Offset: 10)
        let second = IDEAgentSymbol(name: "add", qualifiedName: "demo.A.add", kind: "method", isType: false, detail: "(int): int", fileURL: file, line: 7, utf16Offset: 20)
        let navigator = FakeExploreNavigator()
        let tool = IDEExploreSymbolTool(search: FakeSearch(all: [first, second], files: [file: source]), navigator: navigator, lineText: lineText)

        let output = await runTool(tool, root: project, #"{"name":"A.add"}"#)
        XCTAssertFalse(output.isError, output.text)
        XCTAssertTrue(output.text.hasPrefix("2 declarations match “A.add”."), output.text)
        XCTAssertTrue(output.text.contains("src/A.java:6: method demo.A.add(int, int): int"))
        XCTAssertTrue(output.text.contains("src/A.java:7: method demo.A.add(int): int"))
        XCTAssertTrue(navigator.calls.all.isEmpty, "nothing was looked up for a guess")

        let narrowed = await runTool(tool, root: project, #"{"name":"A.add","line":7}"#)
        XCTAssertTrue(narrowed.text.hasPrefix("demo.A.add — method — src/A.java:7"), narrowed.text)
        XCTAssertEqual(navigator.calls.all.sorted(), [20, 20], "usages and implementations were asked at the picked name")

        let byPath = await runTool(tool, root: project, #"{"name":"add","path":"src/Other.java"}"#)
        XCTAssertTrue(byPath.text.hasPrefix("No project declaration is named “add”"), byPath.text)
    }

    func testAQualifiedNameKeepsOnlyTheDeclarationsInThatOwner() async {
        let inA = IDEAgentSymbol(name: "get", qualifiedName: "demo.A.get", kind: "method", isType: false, detail: nil, fileURL: file, line: 7, utf16Offset: 5)
        let inB = IDEAgentSymbol(name: "get", qualifiedName: "demo.B.get", kind: "method", isType: false, detail: nil, fileURL: file, line: 3, utf16Offset: 5)
        let tool = IDEExploreSymbolTool(search: FakeSearch(all: [inA, inB], files: [file: source]), navigator: FakeExploreNavigator(), lineText: lineText)
        let output = await runTool(tool, root: project, #"{"name":"B.get"}"#)
        XCTAssertTrue(output.text.hasPrefix("demo.B.get — method"), output.text)
    }

    func testATypeShowsItsDocCommentHeaderMembersImplementationsAndUsages() async {
        let other = project.appendingPathComponent("src/B.java")
        try? "class B extends A {}\nclass C { A a; }\n".write(to: other, atomically: true, encoding: .utf8)
        let navigator = FakeExploreNavigator(
            usage: [IDEAgentCodeLocation(fileURL: other, line: 2, label: "", kind: "type")],
            implementation: [IDEAgentCodeLocation(fileURL: other, line: 1, label: "B")])
        let tool = IDEExploreSymbolTool(search: FakeSearch(all: [classA()], files: [file: source]), navigator: navigator, lineText: lineText)

        let output = await runTool(tool, root: project, #"{"name":"A"}"#)
        XCTAssertFalse(output.isError, output.text)
        let lines = output.text.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "demo.A — class — src/A.java:5")
        XCTAssertTrue(lines.contains("Declaration (src/A.java:3-5):"), output.text)
        XCTAssertTrue(lines.contains("     3\t/** Adds things. */"), "the doc comment above the annotation is included")
        XCTAssertTrue(lines.contains("     4\t@Deprecated"))
        XCTAssertTrue(lines.contains("     5\tpublic class A {"), "a type stops at the end of its header, not its body")
        XCTAssertFalse(output.text.contains("return total"), "the body of a type is not part of the declaration")
        XCTAssertTrue(lines.contains("Members (2):"))
        XCTAssertTrue(lines.contains { $0.hasPrefix("src/A.java:6: field total") }, output.text)
        XCTAssertTrue(lines.contains { $0.hasPrefix("src/A.java:7: method get") }, output.text)
        XCTAssertTrue(lines.contains("Implementations (1):"))
        XCTAssertTrue(lines.contains("src/B.java:1: class B extends A {}"))
        XCTAssertTrue(lines.contains("Usages (1 in 1 file):"))
        XCTAssertTrue(lines.contains { $0.hasPrefix("src/B.java:2: class C { A a; }") }, output.text)
    }

    func testAMethodShowsItsWholeBodyAndNoMembers() async {
        let method = IDEAgentSymbol(
            name: "get", qualifiedName: "demo.A.get", kind: "method", isType: false, detail: "(): int", fileURL: file, line: 7,
            utf16Offset: offset(of: "get()"))
        let tool = IDEExploreSymbolTool(search: FakeSearch(all: [method], files: [file: source]), navigator: FakeExploreNavigator(), lineText: lineText)
        let output = await runTool(tool, root: project, #"{"name":"get"}"#)
        XCTAssertTrue(output.text.contains("     7\t    public int get() { return total; }"), output.text)
        XCTAssertFalse(output.text.contains("Members"))
        XCTAssertTrue(output.text.contains("Usages: none found."))
    }

    func testUsagesAreGroupedAndCapped() async {
        let other = project.appendingPathComponent("src/B.java")
        try? "x\n".write(to: other, atomically: true, encoding: .utf8)
        let usage = (1...40).map { IDEAgentCodeLocation(fileURL: other, line: 41 - $0, label: "", kind: "read") }
        let tool = IDEExploreSymbolTool(
            search: FakeSearch(all: [classA()], files: [file: source]), navigator: FakeExploreNavigator(usage: usage), lineText: lineText)
        let output = await runTool(tool, root: project, #"{"name":"A"}"#)
        XCTAssertTrue(output.text.contains("Usages (40 in 1 file):"), output.text)
        XCTAssertEqual(output.text.components(separatedBy: "\n").filter { $0.hasPrefix("src/B.java:") }.count, IDEExploreSymbolTool.maxUsages)
        XCTAssertTrue(output.text.contains("src/B.java:1:"), "sorted by line, so the first rows are the earliest")
        XCTAssertTrue(output.text.hasSuffix("… and 15 more: call find_usages for all of them."))
    }

    func testASymbolTheFileNoLongerHoldsIsNotExplored() async {
        let navigator = FakeExploreNavigator()
        let gone = IDEAgentSymbol(name: "Gone", qualifiedName: "demo.Gone", kind: "class", isType: true, detail: nil, fileURL: file)
        let tool = IDEExploreSymbolTool(search: FakeSearch(all: [gone], files: [file: source]), navigator: navigator, lineText: lineText)
        let output = await runTool(tool, root: project, #"{"name":"Gone"}"#)
        XCTAssertTrue(output.text.contains("not found where the index put it"), output.text)
        XCTAssertTrue(navigator.calls.all.isEmpty)
    }

    func testAnUnknownNameSaysWhetherTheIndexIsStillBuilding() async {
        let building = IDEExploreSymbolTool(
            search: FakeSearch(status: "Indexing project sources…"), navigator: FakeExploreNavigator(), lineText: lineText)
        let output = await runTool(building, root: project, #"{"name":"Nope"}"#)
        XCTAssertTrue(output.text.contains("still being built"), output.text)
        let ready = IDEExploreSymbolTool(search: FakeSearch(), navigator: FakeExploreNavigator(), lineText: lineText)
        let none = await runTool(ready, root: project, #"{"name":"Nope"}"#)
        XCTAssertTrue(none.text.hasPrefix("No project declaration is named “Nope”"), none.text)
    }

    // MARK: cost

    func testTheTwoDefinitionsStayCheap() {
        let search = FakeSearch()
        let definitions = [
            IDEFindSymbolTool(search: search).definition,
            IDEExploreSymbolTool(search: search, navigator: FakeExploreNavigator(), lineText: lineText).definition,
        ]
        let tokens = ToolCost.tokens(of: definitions, provider: "anthropic")
        print("TOOLCOST find_symbol + explore_symbol ≈\(tokens) tokens (Anthropic counting)")
        XCTAssertLessThan(tokens, 700, "the two tools cost ≈\(tokens) tokens in every request")
    }
}

/// The tools over the real Java index, the real structure provider and the real usage search.
final class IDEAgentSymbolIntegrationTests: XCTestCase {
    private func makeFixture() async throws -> (JavaReferenceFixture, JavaReferenceEnvironment) {
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
        return (fixture, try await fixture.build())
    }

    private func search(
        _ environment: JavaReferenceEnvironment, text: (@Sendable (URL) async -> String?)? = nil
    ) -> IDEIndexAgentSymbolSearch {
        IDEIndexAgentSymbolSearch(
            javaIndex: environment.index,
            text: text ?? { try? String(contentsOf: $0, encoding: .utf8) },
            structureProvider: { _ in JavaStructureProvider() },
            status: { nil })
    }

    func testFindSymbolFindsTypesAndEveryOverloadByNameAlone() async throws {
        let (fixture, environment) = try await makeFixture()
        let tool = IDEFindSymbolTool(search: search(environment))
        let type = await runTool(tool, root: fixture.root, #"{"query":"Calc"}"#)
        XCTAssertFalse(type.isError, type.text)
        XCTAssertTrue(type.text.hasPrefix("src/Calc.java:3: class demo.Calc"), "the type leads: \(type.text)")

        let methods = await runTool(tool, root: fixture.root, #"{"query":"add"}"#)
        XCTAssertTrue(methods.text.contains("src/Calc.java:4: method demo.Calc.add"), methods.text)
        XCTAssertTrue(methods.text.contains("src/Calc.java:8: method demo.Calc.add"), methods.text)

        let humps = await runTool(tool, root: fixture.root, #"{"query":"Cal"}"#)
        XCTAssertTrue(humps.text.contains("class demo.Calc"), humps.text)
    }

    func testExploreAnOverloadFromItsNameThenItsLine() async throws {
        let (fixture, environment) = try await makeFixture()
        let paths = JavaIndexPaths(root: fixture.root.appendingPathComponent("cache"))
        let usages = JavaFindUsagesProvider(index: environment.index, indexPaths: paths)
        await usages.setProjectRoots([fixture.root])
        let navigator = IDEJavaAgentNavigator(
            definitionProvider: JavaGoToDefinitionProvider(index: environment.index, indexPaths: paths), usageProvider: usages)
        let tool = IDEExploreSymbolTool(search: search(environment), navigator: navigator, lineText: lineText)

        let both = await runTool(tool, root: fixture.root, #"{"name":"Calc.add"}"#)
        XCTAssertTrue(both.text.hasPrefix("2 declarations match “Calc.add”."), both.text)

        let two = await runTool(tool, root: fixture.root, #"{"name":"Calc.add","line":4}"#)
        XCTAssertFalse(two.isError, two.text)
        XCTAssertTrue(two.text.contains("     5\t        return a + b;"), "the whole body: \(two.text)")
        XCTAssertTrue(two.text.contains("src/Main.java:6:"), "the call in Main: \(two.text)")
        XCTAssertTrue(two.text.contains("src/Calc.java:9:"), "the inner call: \(two.text)")
        XCTAssertFalse(two.text.contains("Members"))
    }

    func testExploreAClassListsItsMembers() async throws {
        let (fixture, environment) = try await makeFixture()
        let paths = JavaIndexPaths(root: fixture.root.appendingPathComponent("cache"))
        let usages = JavaFindUsagesProvider(index: environment.index, indexPaths: paths)
        await usages.setProjectRoots([fixture.root])
        let navigator = IDEJavaAgentNavigator(
            definitionProvider: JavaGoToDefinitionProvider(index: environment.index, indexPaths: paths), usageProvider: usages)
        let tool = IDEExploreSymbolTool(search: search(environment), navigator: navigator, lineText: lineText)
        let output = await runTool(tool, root: fixture.root, #"{"name":"demo.Calc"}"#)
        XCTAssertFalse(output.isError, output.text)
        XCTAssertTrue(output.text.hasPrefix("demo.Calc — class — src/Calc.java:3"), output.text)
        XCTAssertTrue(output.text.contains("Declaration (src/Calc.java:3-3):"), output.text)
        XCTAssertTrue(output.text.contains("Members (2):"), output.text)
        XCTAssertTrue(output.text.contains("src/Main.java:5:"), "`new Calc()` and the declared type are usages: \(output.text)")
    }

    func testAnEditedBufferMovesTheLineAndIsFlagged() async throws {
        let (fixture, environment) = try await makeFixture()
        let calc = fixture.url("src/Calc.java")
        let edited = "// a new header\n// and another\n" + (fixture.sources["src/Calc.java"] ?? "")
        let live: @Sendable (URL) async -> String? = { url in
            url.standardizedFileURL == calc.standardizedFileURL ? edited : try? String(contentsOf: url, encoding: .utf8)
        }
        let tool = IDEFindSymbolTool(search: search(environment, text: live))
        let output = await runTool(tool, root: fixture.root, #"{"query":"Calc"}"#)
        XCTAssertTrue(output.text.contains("src/Calc.java:5: class demo.Calc  (moved since indexing)"), output.text)
        let members = await runTool(tool, root: fixture.root, #"{"query":"add"}"#)
        XCTAssertTrue(members.text.contains("src/Calc.java:6: method demo.Calc.add"), "members follow the live text too: \(members.text)")
        XCTAssertTrue(members.text.contains("src/Calc.java:10: method demo.Calc.add"), members.text)
    }

    func testADeletedDeclarationIsReportedNotInvented() async throws {
        let (fixture, environment) = try await makeFixture()
        let calc = fixture.url("src/Calc.java")
        let live: @Sendable (URL) async -> String? = { url in
            url.standardizedFileURL == calc.standardizedFileURL ? "package demo;\n\nclass Renamed {}\n" : nil
        }
        let tool = IDEFindSymbolTool(search: search(environment, text: live))
        let output = await runTool(tool, root: fixture.root, #"{"query":"Calc"}"#)
        XCTAssertTrue(output.text.contains("not found where the index put it"), output.text)
    }
}
