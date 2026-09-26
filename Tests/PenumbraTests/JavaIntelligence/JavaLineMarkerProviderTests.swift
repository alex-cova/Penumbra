import XCTest
import EditorIntelligence
@testable import JavaIntelligence

final class JavaLineMarkerProviderTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("java-markers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - Implementing and implemented

    func testInterfaceMethodImplementationsGetUpAndDownMarkers() async throws {
        let shape = try write("Shape.java", """
            interface Shape {
                double area();
            }
            """)
        let circle = try write("Circle.java", """
            class Circle implements Shape {
                public double area() { return 1; }
            }
            """)
        let square = try write("Square.java", "class Square implements Shape { public double area() { return 2; } }")
        let files = [shape, circle, square]

        let inCircle = try await markers(for: circle, indexing: files)
        XCTAssertEqual(inCircle.map(\.kind), [.implementing])
        XCTAssertEqual(inCircle.first?.line, 2)
        XCTAssertEqual(inCircle.first?.tooltip, "Implements method in Shape")
        XCTAssertEqual(anchorText(inCircle.first, in: circle), "area")

        let inShape = try await markers(for: shape, indexing: files)
        XCTAssertEqual(inShape.map(\.kind), [.implemented, .implemented])
        XCTAssertEqual(inShape.map(\.line), [1, 2])
        XCTAssertEqual(inShape.first?.tooltip, "Is implemented by Circle and Square")
        XCTAssertEqual(inShape.last?.tooltip, "Is implemented in Circle and Square")
    }

    func testGenericInterfaceMethodIsImplementedThroughTheTypeArgument() async throws {
        let comparable = try write("Cmp.java", "interface Cmp<T> { int compareTo(T other); }")
        let foo = try write("Foo.java", """
            class Foo implements Cmp<Foo> {
                public int compareTo(Foo other) { return 0; }
            }
            """)
        let result = try await markers(for: foo, indexing: [comparable, foo])
        XCTAssertEqual(result.map(\.kind), [.implementing])
        XCTAssertEqual(result.first?.line, 2)
    }

    // MARK: - Overriding and overridden

    func testConcreteOverrideGetsOverridingAndOverriddenMarkers() async throws {
        let base = try write("Base.java", """
            class Base {
                void run() { }
                void idle() { }
            }
            """)
        let child = try write("Child.java", """
            class Child extends Base {
                void run() { }
            }
            """)
        let inChild = try await markers(for: child, indexing: [base, child])
        XCTAssertEqual(inChild.map(\.kind), [.overriding])
        XCTAssertEqual(inChild.first?.tooltip, "Overrides method in Base")

        let inBase = try await markers(for: base, indexing: [base, child])
        XCTAssertEqual(inBase.map { "\($0.line):\($0.kind)" }, ["1:overridden", "2:overridden"])
        XCTAssertEqual(inBase.first?.tooltip, "Is subclassed by Child")
    }

    func testStaticPrivateAndConstructorsGetNoMethodMarkers() async throws {
        let parent = try write("P.java", """
            class P {
                P() { }
                private void a() { }
                static void b() { }
            }
            """)
        let child = try write("Q.java", """
            class Q extends P {
                Q() { }
                private void a() { }
                static void b() { }
            }
            """)
        let inParent = try await markers(for: parent, indexing: [parent, child])
        XCTAssertEqual(inParent.map { "\($0.line):\($0.kind)" }, ["1:overridden"])
        let inChild = try await markers(for: child, indexing: [parent, child])
        XCTAssertEqual(inChild, [])
    }

    func testUnsavedNestedSubclassInTheBufferCounts() async throws {
        let url = scratch.appendingPathComponent("Outer.java")
        let source = """
            class Outer {
                static class A {
                    void m() { }
                }
                static class B extends A {
                    void m() { }
                }
            }
            """
        let result = try await markers(source: source, url: url, indexing: [])
        XCTAssertEqual(result.map { "\($0.line):\($0.kind)" }, ["2:overridden", "3:overridden", "6:overriding"])
    }

    // MARK: - Sibling inherited

    func testSuperclassMethodImplementingASubclassInterfaceIsASibling() async throws {
        let runner = try write("Runner.java", "interface Runner { void run(); }")
        let base = try write("Base.java", """
            class Base {
                public void run() { }
            }
            """)
        let child = try write("Child.java", "class Child extends Base implements Runner { }")
        let result = try await markers(for: base, indexing: [runner, base, child])
        let sibling = try XCTUnwrap(result.first { $0.kind == .siblingInherited })
        XCTAssertEqual(sibling.line, 2)
        XCTAssertEqual(sibling.targets, [.method(declaringClass: "Runner", name: "run", parameterKeys: [])])
        XCTAssertEqual(sibling.tooltip, "Implements Runner.run via subclass Child")

        let provider = try await makeProvider(indexing: [runner, base, child])
        let locations = await provider.siblingTargets(of: sibling, source: base.source, fileURL: base.url, documentID: DocumentID())
        XCTAssertEqual(locations.map { $0.url?.lastPathComponent }, ["Runner.java"])
    }

    func testSubclassThatOverridesIsNotASibling() async throws {
        let runner = try write("Runner.java", "interface Runner { void run(); }")
        let base = try write("Base.java", "class Base { public void run() { } }")
        let child = try write("Child.java", "class Child extends Base implements Runner { public void run() { } }")
        let result = try await markers(for: base, indexing: [runner, base, child])
        XCTAssertFalse(result.contains { $0.kind == .siblingInherited })
    }

    // MARK: - Recursive calls

    func testRecursiveCallsAreMarkedButOverloadsAreNot() async throws {
        let recursive = try write("R.java", """
            class R {
                int fact(int n) {
                    if (n <= 1) return 1;
                    return n * fact(n - 1);
                }
                int fact(String s) {
                    return fact(s.length());
                }
                static int down(int n) {
                    return n == 0 ? 0 : R.down(n - 1);
                }
                void loop() {
                    Runnable r = () -> loop();
                    this.loop();
                }
            }
            """)
        let result = try await markers(for: recursive, indexing: [recursive], kinds: [.recursiveCall])
        XCTAssertEqual(result.map(\.line), [4, 10, 14])
        XCTAssertEqual(anchorText(result.first, in: recursive), "fact")
    }

    func testKindsFilterLimitsTheResult() async throws {
        let base = try write("Base.java", "class Base { void run() { } }")
        let child = try write("Child.java", "class Child extends Base { void run() { run(); } }")
        let result = try await markers(for: child, indexing: [base, child], kinds: [.overridden])
        XCTAssertEqual(result, [])
    }

    // MARK: - Line table

    func testLineTableCountsCRLFAsOneBreakAndMultibyteAsUTF16() {
        let table = JavaLineTable("a\r\nb\rc\né𝄞x")
        XCTAssertEqual(table.line(ofByte: 0), 1)
        XCTAssertEqual(table.line(ofByte: 3), 2)
        XCTAssertEqual(table.line(ofByte: 5), 3)
        XCTAssertEqual(table.line(ofByte: 7), 4)
        // "é" is 2 bytes / 1 unit, "𝄞" 4 bytes / 2 units.
        XCTAssertEqual(table.utf16Offset(ofByte: 7 + 2 + 4), 7 + 1 + 2)
    }

    // MARK: - Helpers

    private struct Fixture {
        let url: URL
        let source: String
    }

    private func write(_ name: String, _ source: String) throws -> Fixture {
        let url = scratch.appendingPathComponent(name)
        try source.write(to: url, atomically: true, encoding: .utf8)
        return Fixture(url: url, source: source)
    }

    private func makeProvider(indexing files: [Fixture]) async throws -> JavaLineMarkerProvider {
        let index = JavaIndex()
        let stubs = files.flatMap { JavaSourceStubBuilder.build(source: $0.source, url: $0.url).classes }
        if !stubs.isEmpty {
            let shard = scratch.appendingPathComponent("\(UUID().uuidString).idx")
            try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: shard)
            await index.setSources([.init(precedence: 1, reader: try JavaIndexShardReader(url: shard))])
        }
        return JavaLineMarkerProvider(index: index, indexPaths: JavaIndexPaths(root: scratch.appendingPathComponent("cache")))
    }

    private func markers(
        for fixture: Fixture, indexing files: [Fixture], kinds: Set<JavaLineMarkerKind> = Set(JavaLineMarkerKind.allCases)
    ) async throws -> [JavaLineMarker] {
        try await markers(source: fixture.source, url: fixture.url, indexing: files, kinds: kinds)
    }

    private func markers(
        source: String, url: URL, indexing files: [Fixture], kinds: Set<JavaLineMarkerKind> = Set(JavaLineMarkerKind.allCases)
    ) async throws -> [JavaLineMarker] {
        let provider = try await makeProvider(indexing: files)
        let result = await provider.markers(source: source, fileURL: url, kinds: kinds)
        return try XCTUnwrap(result)
    }

    private func anchorText(_ marker: JavaLineMarker?, in fixture: Fixture) -> String? {
        guard let marker else { return nil }
        let ns = fixture.source as NSString
        var end = marker.anchorUTF16Offset
        while end < ns.length, let scalar = UnicodeScalar(ns.character(at: end)), CharacterSet.alphanumerics.contains(scalar) {
            end += 1
        }
        return ns.substring(with: NSRange(location: marker.anchorUTF16Offset, length: end - marker.anchorUTF16Offset))
    }
}
