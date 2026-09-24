import EditorIntelligence
import XCTest
@testable import JavaIntelligence

final class JavaMemberRenameTests: XCTestCase {
    private var fixture: JavaReferenceFixture!
    private var markerOffsets: [String: Int] = [:]

    override func setUpWithError() throws {
        fixture = try JavaReferenceFixture()
    }

    func testOverloadSiblingsAreUntouched() async throws {
        try add("p/T.java", """
        package p;
        class T {
            void €run(int a) {}
            void run(String s) {}
            void use() { run(1); run("x"); this.run(2); }
        }
        """)
        let (provider, context) = try await makeProvider(caretIn: "p/T.java")
        let plan = try await provider.rename(context, to: "go")
        XCTAssertNil(plan.blockingError)
        let text = try XCTUnwrap(apply(plan)["p/T.java"])
        XCTAssertTrue(text.contains("void go(int a) {}"))
        XCTAssertTrue(text.contains("void run(String s) {}"))
        XCTAssertTrue(text.contains("go(1); run(\"x\"); this.go(2);"), text)
    }

    func testInterfaceMethodRenamesImplementationsInTwoFiles() async throws {
        try add("p/Shape.java", "package p; public interface Shape { double €area(); }")
        try add("p/Circle.java", "package p; public class Circle implements Shape { @Override public double area() { return 1; } }")
        try add("p/Square.java", "package p; public class Square implements Shape { public double area() { return 2; } }")
        try add("p/Use.java", """
        package p;
        class Use { double f(Shape s, Circle c) { return s.area() + c.area(); } }
        """)
        let (provider, context) = try await makeProvider(caretIn: "p/Shape.java")
        let plan = try await provider.rename(context, to: "surface")
        XCTAssertNil(plan.blockingError)
        let result = try apply(plan)
        XCTAssertTrue(try XCTUnwrap(result["p/Shape.java"]).contains("double surface();"))
        XCTAssertTrue(try XCTUnwrap(result["p/Circle.java"]).contains("public double surface()"))
        XCTAssertTrue(try XCTUnwrap(result["p/Square.java"]).contains("public double surface()"))
        XCTAssertTrue(try XCTUnwrap(result["p/Use.java"]).contains("s.surface() + c.surface()"))
    }

    func testRenamingOverrideRenamesSuperclassAndSiblings() async throws {
        try add("p/Base.java", "package p; public class Base { public void work() {} }")
        try add("p/Sub.java", """
        package p;
        public class Sub extends Base {
            @Override public void €work() { super.work(); }
        }
        """)
        try add("p/Other.java", "package p; public class Other extends Base { public void work() {} void f(Base b) { b.work(); } }")
        let (provider, context) = try await makeProvider(caretIn: "p/Sub.java")
        let plan = try await provider.rename(context, to: "perform")
        XCTAssertNil(plan.blockingError)
        let result = try apply(plan)
        XCTAssertTrue(try XCTUnwrap(result["p/Base.java"]).contains("public void perform() {}"))
        XCTAssertTrue(try XCTUnwrap(result["p/Sub.java"]).contains("public void perform() { super.perform(); }"))
        let other = try XCTUnwrap(result["p/Other.java"])
        XCTAssertTrue(other.contains("public void perform() {}"))
        XCTAssertTrue(other.contains("b.perform()"))
    }

    func testLibraryOverrideIsBlocked() async throws {
        // `lib.Greeter` lives in a JAR shard; the project class implements it.
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
        let provider = JavaRenameProvider(
            index: index, indexPaths: JavaIndexPaths(root: fixture.root.appendingPathComponent("cache")),
            candidates: JavaTextScanCandidateSource()
        )
        await provider.setRoots([fixture.root])
        let plan = try await provider.rename(try makeContext(file: "p/T.java"), to: "hello")
        XCTAssertTrue(plan.blockingError?.contains("overrides a library method") == true, "\(String(describing: plan.blockingError))")
    }

    func testStaticMethodAndStaticImport() async throws {
        try add("p/Util.java", "package p; public class Util { public static int €twice(int x) { return x * 2; } }")
        try add("q/User.java", """
        package q;
        import static p.Util.twice;
        import p.Util;
        class User { int a = twice(1) + Util.twice(2); }
        """)
        let (provider, context) = try await makeProvider(caretIn: "p/Util.java")
        let plan = try await provider.rename(context, to: "doubled")
        XCTAssertNil(plan.blockingError)
        let result = try apply(plan)
        XCTAssertTrue(try XCTUnwrap(result["p/Util.java"]).contains("static int doubled(int x)"))
        let user = try XCTUnwrap(result["q/User.java"])
        XCTAssertTrue(user.contains("import static p.Util.doubled;"))
        XCTAssertTrue(user.contains("doubled(1) + Util.doubled(2)"))
    }

    func testMethodReference() async throws {
        try add("p/T.java", """
        package p;
        import java.util.function.Supplier;
        class T {
            int €make() { return 1; }
            Supplier<Integer> s = this::make;
            static int stat() { return 2; }
            Supplier<Integer> t = T::stat;
        }
        """)
        let (provider, context) = try await makeProvider(caretIn: "p/T.java")
        let plan = try await provider.rename(context, to: "build")
        let text = try XCTUnwrap(apply(plan)["p/T.java"])
        XCTAssertTrue(text.contains("int build()"))
        XCTAssertTrue(text.contains("this::build"))
        XCTAssertTrue(text.contains("T::stat"))
    }

    func testEnumConstantRename() async throws {
        try add("p/Color.java", "package p; public enum Color { €RED, GREEN }")
        try add("p/Use.java", """
        package p;
        class Use {
            Color c = Color.RED;
            int f(Color x) { switch (x) { case RED: return 1; default: return 0; } }
        }
        """)
        let (provider, context) = try await makeProvider(caretIn: "p/Color.java")
        let prepared = await provider.prepareRename(context)
        XCTAssertEqual(prepared?.kindDescription, "enum constant")
        let plan = try await provider.rename(context, to: "CRIMSON")
        XCTAssertNil(plan.blockingError)
        let result = try apply(plan)
        XCTAssertTrue(try XCTUnwrap(result["p/Color.java"]).contains("{ CRIMSON, GREEN }"))
        let use = try XCTUnwrap(result["p/Use.java"])
        XCTAssertTrue(use.contains("Color.CRIMSON"))
        XCTAssertTrue(use.contains("case CRIMSON:"), use)
    }

    func testRecordComponentRenamesAccessorUsages() async throws {
        try add("p/Point.java", """
        package p;
        public record Point(int €x, int y) {
            public Point {
                if (x < 0) throw new IllegalArgumentException();
            }
        }
        """)
        try add("p/Use.java", "package p; class Use { int f(Point p) { return p.x() + p.y(); } }")
        let (provider, context) = try await makeProvider(caretIn: "p/Point.java")
        let plan = try await provider.rename(context, to: "left")
        XCTAssertNil(plan.blockingError)
        let result = try apply(plan)
        let point = try XCTUnwrap(result["p/Point.java"])
        XCTAssertTrue(point.contains("Point(int left, int y)"))
        XCTAssertTrue(point.contains("if (left < 0)"))
        XCTAssertTrue(try XCTUnwrap(result["p/Use.java"]).contains("p.left() + p.y()"))
    }

    func testFieldWithGetterWarnsButKeepsGetter() async throws {
        try add("p/Person.java", """
        package p;
        public class Person {
            private String €name;
            public String getName() { return name; }
            public void setName(String name) { this.name = name; }
        }
        """)
        try add("p/Use.java", "package p; class Use { String f(Person p) { return p.getName(); } }")
        let (provider, context) = try await makeProvider(caretIn: "p/Person.java")
        let prepared = await provider.prepareRename(context)
        XCTAssertEqual(prepared?.kindDescription, "field")
        let plan = try await provider.rename(context, to: "title")
        XCTAssertNil(plan.blockingError)
        XCTAssertTrue(plan.warnings.contains { $0.contains("getName") && $0.contains("setName") })
        let text = try XCTUnwrap(apply(plan)["p/Person.java"])
        XCTAssertTrue(text.contains("private String title;"))
        XCTAssertTrue(text.contains("return title;"))
        XCTAssertTrue(text.contains("this.title = name;"))
        XCTAssertTrue(text.contains("getName()"))
        XCTAssertTrue(text.contains("setName(String name)"))
        // The parameter `name` in the setter is a different symbol and shadows nothing new.
        XCTAssertNil(try apply(plan)["p/Use.java"])
    }

    func testFieldShadowedByLocalWarns() async throws {
        try add("p/T.java", """
        package p;
        class T {
            int €count;
            int f() { int total = 1; return count + total; }
        }
        """)
        let (provider, context) = try await makeProvider(caretIn: "p/T.java")
        let plan = try await provider.rename(context, to: "total")
        XCTAssertTrue(plan.warnings.contains { $0.contains("shadow") }, "\(plan.warnings)")
    }

    func testMethodNameConflictWarns() async throws {
        try add("p/T.java", """
        package p;
        class T {
            void €a(int x) {}
            void b(int y) {}
        }
        """)
        let (provider, context) = try await makeProvider(caretIn: "p/T.java")
        let plan = try await provider.rename(context, to: "b")
        XCTAssertNil(plan.blockingError)
        XCTAssertTrue(plan.warnings.contains { $0.contains("already declares b(") }, "\(plan.warnings)")
    }

    func testFieldNameConflictWarns() async throws {
        try add("p/T.java", "package p; class T { int €a; int b; }")
        let (provider, context) = try await makeProvider(caretIn: "p/T.java")
        let plan = try await provider.rename(context, to: "b")
        XCTAssertTrue(plan.warnings.contains { $0.contains("already has a field named b") })
    }

    // MARK: - Helpers

    private func add(_ name: String, _ marked: String) throws {
        if let marker = marked.range(of: "€") {
            markerOffsets[name] = marked.utf16.distance(from: marked.utf16.startIndex, to: marker.lowerBound.samePosition(in: marked.utf16)!)
        }
        try fixture.add(name, marked)
    }

    private func makeProvider(caretIn file: String) async throws -> (JavaRenameProvider, NavigationContext) {
        let environment = try await fixture.build()
        let provider = JavaRenameProvider(
            index: environment.index, indexPaths: JavaIndexPaths(root: fixture.root.appendingPathComponent("cache")),
            candidates: JavaTextScanCandidateSource()
        )
        await provider.setRoots([fixture.root])
        return (provider, try makeContext(file: file))
    }

    private func makeContext(file: String) throws -> NavigationContext {
        let source = try XCTUnwrap(fixture.sources[file])
        let offset = try XCTUnwrap(markerOffsets[file])
        let position = JavaNavigationText.position(utf16Offset: offset, in: source)
        let document = Document(
            url: fixture.url(file), displayName: file,
            contentSnapshot: TextSnapshot(version: 0, text: source),
            selection: Selection(range: EditorIntelligence.TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: "java"
        )
        return NavigationContext(document: document, cursor: Cursor(position: position), selection: document.selection)
    }

    private func apply(_ plan: RenamePlan) throws -> [String: String] {
        let ids = Set(plan.entries.filter { !$0.isReadOnly && !$0.isAmbiguous }.map(\.id))
        let edit = plan.workspaceEdit(including: ids)
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
