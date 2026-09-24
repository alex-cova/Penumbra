import EditorIntelligence
import XCTest
@testable import JavaIntelligence

final class JavaChangeSignatureTests: XCTestCase {
    private var fixture: JavaReferenceFixture!
    private var markerOffsets: [String: Int] = [:]

    override func setUpWithError() throws {
        fixture = try JavaReferenceFixture()
    }

    func testRenameMethodUpdatesDeclarationAndCallSites() async throws {
        try add("p/Util.java", """
        package p;
        public class Util {
            public static int €twice(int x) { return x * 2; }
        }
        """)
        try add("q/User.java", """
        package q;
        import p.Util;
        class User { int a = Util.twice(1); }
        """)
        let plan = try await plan(request: .init(newName: "doubled", addParameter: nil, removeLastParameter: false))
        XCTAssertNil(plan.blockingError)
        let result = try apply(plan)
        XCTAssertTrue(try XCTUnwrap(result["p/Util.java"]).contains("static int doubled(int x)"))
        XCTAssertTrue(try XCTUnwrap(result["q/User.java"]).contains("Util.doubled(1)"))
    }

    func testAddTrailingParameterInsertsDefaultAtCallSites() async throws {
        try add("p/T.java", """
        package p;
        class T {
            void €run(int a) {}
            void use() { run(1); }
        }
        """)
        let plan = try await plan(request: .init(
            newName: "run", addParameter: (type: "int", name: "flags", defaultValue: "0"), removeLastParameter: false
        ))
        XCTAssertNil(plan.blockingError)
        let text = try XCTUnwrap(apply(plan)["p/T.java"])
        XCTAssertTrue(text.contains("void run(int a, int flags)"))
        XCTAssertTrue(text.contains("run(1, 0);"))
    }

    func testRemoveLastParameterDropsArgumentAtCallSites() async throws {
        try add("p/T.java", """
        package p;
        class T {
            void €run(int a, String b) {}
            void use() { run(1, "x"); }
        }
        """)
        let plan = try await plan(request: .init(newName: "run", addParameter: nil, removeLastParameter: true))
        XCTAssertNil(plan.blockingError)
        let text = try XCTUnwrap(apply(plan)["p/T.java"])
        XCTAssertTrue(text.contains("void run(int a)"))
        XCTAssertTrue(text.contains("run(1);"))
    }

    func testRenameAndAddParameterAcrossOverrideFamily() async throws {
        try add("p/Base.java", "package p; public class Base { public void €work(int a) {} }")
        try add("p/Sub.java", """
        package p;
        public class Sub extends Base {
            @Override public void work(int a) {}
            void f() { work(1); }
        }
        """)
        try add("p/Use.java", "package p; class Use { void g(Base b) { b.work(2); } }")
        let plan = try await plan(
            caretIn: "p/Base.java",
            request: .init(newName: "perform", addParameter: (type: "boolean", name: "flag", defaultValue: "false"), removeLastParameter: false)
        )
        XCTAssertNil(plan.blockingError)
        let result = try apply(plan)
        XCTAssertTrue(try XCTUnwrap(result["p/Base.java"]).contains("public void perform(int a, boolean flag)"))
        XCTAssertTrue(try XCTUnwrap(result["p/Sub.java"]).contains("public void perform(int a, boolean flag)"))
        XCTAssertTrue(try XCTUnwrap(result["p/Sub.java"]).contains("perform(1, false);"))
        XCTAssertTrue(try XCTUnwrap(result["p/Use.java"]).contains("b.perform(2, false);"))
    }

    func testOverloadSiblingsAreUntouched() async throws {
        try add("p/T.java", """
        package p;
        class T {
            void €run(int a) {}
            void run(String s) {}
            void use() { run(1); run("x"); }
        }
        """)
        let plan = try await plan(request: .init(newName: "go", addParameter: nil, removeLastParameter: false))
        XCTAssertNil(plan.blockingError)
        let text = try XCTUnwrap(apply(plan)["p/T.java"])
        XCTAssertTrue(text.contains("void go(int a)"))
        XCTAssertTrue(text.contains("void run(String s)"))
        XCTAssertTrue(text.contains("go(1); run(\"x\");"), text)
    }

    func testLibraryOverrideIsBlocked() async throws {
        let greet = JavaMethodStub(name: "greet", parameters: [], returnType: .void, modifiers: [.publicFlag, .abstractFlag])
        let jarStub = JavaClassStub(
            binaryName: "lib.Greeter", qualifiedName: "lib.Greeter", simpleName: "Greeter", packageName: "lib",
            kind: .interfaceKind, modifiers: [.publicFlag], methods: [greet], origin: .jar(fixture.root.appendingPathComponent("lib.jar"))
        )
        try add("p/T.java", """
        package p;
        class T implements lib.Greeter {
            @Override public void €greet() {}
        }
        """)
        let sourceStubs = JavaSourceStubBuilder.build(source: try XCTUnwrap(fixture.sources["p/T.java"]), url: fixture.url("p/T.java")).classes
        let jarShard = fixture.root.appendingPathComponent("jar.idx")
        let srcShard = fixture.root.appendingPathComponent("src.idx")
        let stamp = JavaStamp(size: 0, modificationDate: 0)
        try JavaIndexShardWriter().write([jarStub], stamp: stamp, to: jarShard)
        try JavaIndexShardWriter().write(sourceStubs, stamp: stamp, to: srcShard)
        let index = JavaIndex()
        await index.setSources([
            .init(precedence: 1, reader: try JavaIndexShardReader(url: srcShard)),
            .init(precedence: 2, reader: try JavaIndexShardReader(url: jarShard))
        ])
        let environment = JavaReferenceEnvironment(index: index, cacheRoot: fixture.root.appendingPathComponent("cache"))
        let caret = try XCTUnwrap(markerOffsets["p/T.java"])
        let plan = await JavaChangeSignature.plan(
            source: try XCTUnwrap(fixture.sources["p/T.java"]), caretOffset: caret, url: fixture.url("p/T.java"),
            request: .init(newName: "hello", addParameter: nil, removeLastParameter: false),
            index: index, candidates: JavaTextScanCandidateSource(), roots: [fixture.root],
            environment: environment, isReadOnly: { _ in false }
        )
        XCTAssertTrue(plan.blockingError?.contains("overrides a library method") == true)
    }

    func testRebuildFormalParametersHelpers() {
        let source = "class T { void run(int a, String b) {} }"
        guard let tree = JavaSyntaxParser().parse(source),
              let method = tree.rootNode.namedChildren.first(where: { $0.type == "class_declaration" })?
                .child(byFieldName: "body")?.namedChildren.first(where: { $0.type == "method_declaration" }),
              let parameters = method.child(byFieldName: "parameters") else {
            return XCTFail("parse")
        }
        XCTAssertEqual(JavaChangeSignature.rebuildFormalParameters(parameters, add: ("boolean", "flag"), removeLast: false), "(int a, String b, boolean flag)")
        XCTAssertEqual(JavaChangeSignature.rebuildFormalParameters(parameters, add: nil, removeLast: true), "(int a)")
    }

    // MARK: - Helpers

    private func add(_ name: String, _ marked: String) throws {
        if let marker = marked.range(of: "€") {
            markerOffsets[name] = marked.utf16.distance(from: marked.utf16.startIndex, to: marker.lowerBound.samePosition(in: marked.utf16)!)
        }
        try fixture.add(name, marked)
    }

    private func plan(
        caretIn file: String? = nil, request: JavaChangeSignature.Request
    ) async throws -> WorkspaceEditPlan {
        let environment = try await fixture.build()
        let caretFile = file ?? markerOffsets.keys.sorted().first!
        let caret = try XCTUnwrap(markerOffsets[caretFile])
        return await JavaChangeSignature.plan(
            source: try XCTUnwrap(fixture.sources[caretFile]), caretOffset: caret, url: fixture.url(caretFile),
            request: request, index: environment.index, candidates: JavaTextScanCandidateSource(),
            roots: [fixture.root], environment: environment, isReadOnly: { _ in false }
        )
    }

    private func apply(_ plan: WorkspaceEditPlan) throws -> [String: String] {
        let edit = plan.workspaceEdit()
        var result: [String: String] = [:]
        for url in edit.changes.keys {
            var text = try String(contentsOf: url, encoding: .utf8) as NSString
            for change in edit.orderedEdits(for: url) {
                let length = change.range.end.utf16Offset - change.range.start.utf16Offset
                text = text.replacingCharacters(
                    in: NSRange(location: change.range.start.utf16Offset, length: length), with: change.replacement
                ) as NSString
            }
            let prefix = fixture.root.standardizedFileURL.path + "/"
            result[url.standardizedFileURL.path.replacingOccurrences(of: prefix, with: "")] = text as String
        }
        return result
    }
}
