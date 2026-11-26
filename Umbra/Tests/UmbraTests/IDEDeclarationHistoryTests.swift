import EditorIntelligence
import Foundation
import GitIntelligence
import XCTest
@testable import Umbra

final class IDEDeclarationHistoryTests: XCTestCase {
    private func node(_ title: String, _ kind: StructureKind, _ body: Range<Int>, _ children: [StructureNode] = []) -> StructureNode {
        StructureNode(id: title, title: title, kind: kind, nameRange: body.lowerBound..<(body.lowerBound + 1), bodyRange: body, children: children)
    }

    /// `Outer` holds the methods a and b and a nested `Inner` with the method c.
    private var outline: [StructureNode] {
        [node("Outer", .type, 0..<200, [
            node("a()", .method, 10..<50),
            node("b(int)", .method, 60..<120),
            node("Inner", .type, 130..<190, [node("c()", .method, 140..<180)])
        ])]
    }

    func testTheMethodAroundTheCaretIsTheInnermostOne() {
        let roots = outline
        XCTAssertEqual(IDEDeclarationHistory.declaration(in: roots, containing: 20, kind: .method)?.title, "a()")
        XCTAssertEqual(IDEDeclarationHistory.declaration(in: roots, containing: 100, kind: .method)?.title, "b(int)")
        XCTAssertEqual(IDEDeclarationHistory.declaration(in: roots, containing: 150, kind: .method)?.title, "c()")
        // The caret just after a body still belongs to it, as in the Structure tab.
        XCTAssertEqual(IDEDeclarationHistory.declaration(in: roots, containing: 50, kind: .method)?.title, "a()")
    }

    func testTheClassAroundTheCaretIsTheInnermostOne() {
        let roots = outline
        XCTAssertEqual(IDEDeclarationHistory.declaration(in: roots, containing: 150, kind: .type)?.title, "Inner")
        XCTAssertEqual(IDEDeclarationHistory.declaration(in: roots, containing: 20, kind: .type)?.title, "Outer")
        XCTAssertEqual(IDEDeclarationHistory.declaration(in: roots, containing: 5, kind: .type)?.title, "Outer")
    }

    func testNoDeclarationOfTheKindMeansNone() {
        let roots = outline
        // A field area of the class: a class, but no method.
        XCTAssertNil(IDEDeclarationHistory.declaration(in: roots, containing: 5, kind: .method))
        XCTAssertNil(IDEDeclarationHistory.declaration(in: roots, containing: 300, kind: .method))
        XCTAssertNil(IDEDeclarationHistory.declaration(in: roots, containing: 300, kind: .type))
        XCTAssertNil(IDEDeclarationHistory.declaration(in: [], containing: 0, kind: .method))
    }

    func testConstructorsAndFreeFunctionsCountAsMethods() {
        let roots = [
            node("init()", .constructor, 0..<20),
            node("helper()", .function, 30..<60)
        ]
        XCTAssertEqual(IDEDeclarationHistory.declaration(in: roots, containing: 5, kind: .method)?.title, "init()")
        XCTAssertEqual(IDEDeclarationHistory.declaration(in: roots, containing: 40, kind: .method)?.title, "helper()")
        XCTAssertNil(IDEDeclarationHistory.declaration(in: [node("x", .field, 0..<10)], containing: 5, kind: .method))
    }

    func testTheHeadingNamesTheKindAndTheDeclaration() {
        let method = node("put(String, int)", .method, 0..<10)
        XCTAssertEqual(IDEDeclarationHistory.title(of: method, kind: .method), "method put(String, int)")
        XCTAssertEqual(IDEDeclarationHistory.title(of: node("Cache", .type, 0..<10), kind: .type), "class Cache")
    }
}

/// `log -L` over a declaration's lines follows the method as it moves down the file.
@MainActor
final class IDEDeclarationHistoryGitTests: XCTestCase {
    private var directory: URL!
    private let runner = SystemGitRunner()

    override func setUp() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: SystemGitRunner.executablePath),
                          "git is not installed at \(SystemGitRunner.executablePath)")
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-decl-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "Tester"],
                     ["config", "user.email", "t@example.com"], ["config", "commit.gpgsign", "false"]] {
            _ = try await runner.run(args, in: directory)
        }
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func commit(_ text: String, _ message: String) async throws {
        try text.write(to: directory.appendingPathComponent("A.java"), atomically: true, encoding: .utf8)
        _ = try await runner.run(["add", "A.java"], in: directory)
        _ = try await runner.run(["commit", "-q", "-m", message], in: directory)
    }

    func testAMethodsHistoryFollowsItDownTheFileAndIgnoresTheOtherMethods() async throws {
        let one = "    int one() {\n        return 1;\n    }\n"
        let two = "    int two() {\n        return 2;\n    }\n"
        try await commit("class A {\n\(one)\(two)}\n", "both methods")
        try await commit("class A {\n\(one)    int two() {\n        return 22;\n    }\n}\n", "change two")
        try await commit("class A {\n    int one() {\n        return 11;\n    }\n    int two() {\n        return 22;\n    }\n}\n", "change one")
        // Lines inserted above both: two() now starts on line 12.
        let header = (1...6).map { "    int filler\($0);\n" }.joined()
        try await commit("class A {\n\(header)    int one() {\n        return 11;\n    }\n    int two() {\n        return 22;\n    }\n}\n", "add fields")

        let model = IDEGitStatusModel()
        model.setRoot(directory)
        let deadline = Date().addingTimeInterval(10)
        while !model.isRepository, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(model.isRepository)

        // two() at HEAD: lines 11-13 of the file (class line, six fields, one() takes 3, then two()).
        model.showLineHistory(path: directory.appendingPathComponent("A.java").path, startLine: 11, endLine: 13,
                              title: "method two()")
        let deadline2 = Date().addingTimeInterval(10)
        while model.lineHistory?.hasLoaded != true, Date() < deadline2 { try await Task.sleep(nanoseconds: 50_000_000) }
        let history = try XCTUnwrap(model.lineHistory)
        XCTAssertEqual(history.title, "method two()")
        XCTAssertEqual(history.entries.map(\.commit.subject), ["change two", "both methods"],
                       "the method's own edits, not the field insert above it or the change to one()")
    }
}
