import EditorIntelligence
import XCTest
@testable import JavaIntelligence

final class JavaCallHierarchyTests: XCTestCase {
    private func makeProvider(_ fixture: JavaReferenceFixture) async throws -> JavaCallHierarchyProvider {
        let paths = JavaIndexPaths(root: fixture.root.appendingPathComponent("cache", isDirectory: true))
        let environment = try await fixture.build(indexPaths: paths)
        let findUsages = JavaFindUsagesProvider(index: environment.index, indexPaths: paths)
        await findUsages.setProjectRoots([fixture.root])
        let sources = fixture.sources
        await findUsages.setOpenBufferLookup { url in
            sources[url.lastPathComponent]
        }
        let provider = JavaCallHierarchyProvider(index: environment.index, indexPaths: paths, findUsages: findUsages)
        await provider.setProjectRoots([fixture.root])
        await provider.setOpenBufferLookup { url in
            sources[url.lastPathComponent]
        }
        return provider
    }

    private func rootMethod(_ provider: JavaCallHierarchyProvider, _ fixture: JavaReferenceFixture) async throws -> JavaCallHierarchyNode {
        let caret = try XCTUnwrap(fixture.caretLocation)
        let source = try XCTUnwrap(fixture.sources[caret.file])
        let node = await provider.rootMethod(source: source, fileURL: fixture.url(caret.file), utf16Offset: caret.utf16Offset)
        return try XCTUnwrap(node, "no method at the caret")
    }

    func testCalleesListDirectInvocationsFromTheMethodBody() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Helper.java", "class Helper { static void help() { } }")
        try fixture.add("Chain.java", """
        class Chain {
            void €caller() { Helper.help(); }
        }
        """)
        let provider = try await makeProvider(fixture)
        let root = try await rootMethod(provider, fixture)
        let callees = await provider.callees(of: root, file: fixture.url("Chain.java"))
        XCTAssertEqual(callees.map(\.displayName), ["Helper.help()"])
        XCTAssertEqual(callees.first?.origin, .source)
    }

    func testTheGenericProtocolWrapsCallersAndKeepsTheNode() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Chain.java", """
        class Chain {
            void €caller() { callee(); }
            void callee() { }
        }
        """)
        try fixture.add("Use.java", "class Use { void go(Chain c) { c.caller(); } }")
        let provider = try await makeProvider(fixture)
        let generic: any CallHierarchyProviding = provider
        let caret = try XCTUnwrap(fixture.caretLocation)
        let source = try XCTUnwrap(fixture.sources[caret.file])
        let rootOptional = await generic.rootItem(source: source, fileURL: fixture.url(caret.file), utf16Offset: caret.utf16Offset)
        let root = try XCTUnwrap(rootOptional)
        XCTAssertEqual(root.kind, .method)
        XCTAssertNotNil(root.payload as? JavaCallHierarchyNode)

        let callers = await generic.callers(of: root, file: fixture.url("Chain.java"))
        XCTAssertEqual(callers.map(\.name), ["Use.go(Chain)"])
        XCTAssertEqual(callers.first?.origin, .project)
        XCTAssertEqual(callers.first?.detail, "Use")

        let foreign = HierarchyItem(id: "x", name: "X", kind: .method, origin: .project)
        let none = await generic.callers(of: foreign, file: nil)
        XCTAssertTrue(none.isEmpty)
    }

    func testCallersListEnclosingMethodsAtCallSites() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Chain.java", """
        class Chain {
            void €caller() { callee(); }
            void callee() { }
        }
        """)
        try fixture.add("Use.java", "class Use { void go(Chain c) { c.caller(); } }")
        let provider = try await makeProvider(fixture)
        let root = try await rootMethod(provider, fixture)
        let callers = await provider.callers(of: root, file: fixture.url("Chain.java"))
        XCTAssertEqual(callers.map(\.displayName), ["Use.go(Chain)"])
        XCTAssertEqual(callers.first?.origin, .source)
    }

    func testRootMethodRequiresCaretOnAMethodOrAField() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("A.java", "class A { void run() { int €local = 1; } }")
        let provider = try await makeProvider(fixture)
        let caret = try XCTUnwrap(fixture.caretLocation)
        let source = try XCTUnwrap(fixture.sources[caret.file])
        let root = await provider.rootMethod(source: source, fileURL: fixture.url(caret.file), utf16Offset: caret.utf16Offset)
        XCTAssertNil(root, "a local variable has no hierarchy")
    }

    func testAFieldIsARootAndItsCallersAreTheMethodsThatUseIt() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Counter.java", """
        class Counter {
            int €count;
            void increment() { count++; }
            int read() { return count; }
            void unrelated() { int count = 3; }
        }
        """)
        try fixture.add("Use.java", "class Use { int peek(Counter c) { return c.count; } }")
        let provider = try await makeProvider(fixture)
        let root = try await rootMethod(provider, fixture)
        XCTAssertEqual(root.displayName, "Counter.count")

        let callers = await provider.callers(of: root, file: fixture.url("Counter.java"))
        XCTAssertEqual(callers.map(\.displayName), ["Counter.increment()", "Counter.read()", "Use.peek(Counter)"])
        XCTAssertTrue(callers.allSatisfy { $0.origin == .source })
    }

    func testAFieldHasNoCallees() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Counter.java", "class Counter { int €count; void increment() { count++; } }")
        let provider = try await makeProvider(fixture)
        let root = try await rootMethod(provider, fixture)
        let callees = await provider.callees(of: root, file: fixture.url("Counter.java"))
        XCTAssertTrue(callees.isEmpty)
    }

    func testAFieldLocationSelectsItsName() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Counter.java", "class Counter { int €count; void increment() { count++; } }")
        let provider = try await makeProvider(fixture)
        let root = try await rootMethod(provider, fixture)
        let location = await provider.location(of: root, file: fixture.url("Counter.java"))
        let found = try XCTUnwrap(location, "a source field has a location")
        XCTAssertEqual(found.url?.lastPathComponent, "Counter.java")
        let text = try String(contentsOf: try XCTUnwrap(found.url), encoding: .utf8) as NSString
        XCTAssertEqual(
            text.substring(with: NSRange(location: found.range.start.utf16Offset, length: found.range.end.utf16Offset - found.range.start.utf16Offset)),
            "count"
        )
    }

    func testLocationSelectsTheDeclaringMethodName() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Chain.java", """
        class Chain {
            void €caller() { }
        }
        """)
        let provider = try await makeProvider(fixture)
        let root = try await rootMethod(provider, fixture)
        let location = await provider.location(of: root, file: fixture.url("Chain.java"))
        let found = try XCTUnwrap(location, "a source method has a location")
        XCTAssertEqual(found.url?.lastPathComponent, "Chain.java")
        let text = try String(contentsOf: try XCTUnwrap(found.url), encoding: .utf8) as NSString
        XCTAssertEqual(
            text.substring(with: NSRange(location: found.range.start.utf16Offset, length: found.range.end.utf16Offset - found.range.start.utf16Offset)),
            "caller"
        )
    }

    /// Regression: the declaring file's text was replaced by an empty string whenever the request
    /// came from the file that declares the method, so callees and locations in the open file were
    /// empty. A request from another file must find the same declaration.
    func testCalleesAndLocationResolveFromTheDeclaringFileWhenAskedFromAnother() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Helper.java", "class Helper { static int help(int n) { return n; } }")
        try fixture.add("Chain.java", """
        class Chain {
            void €caller() { Helper.help(1); local(); }
            void local() { }
        }
        """)
        try fixture.add("Use.java", "class Use { void go(Chain c) { c.caller(); } }")
        let provider = try await makeProvider(fixture)
        let root = try await rootMethod(provider, fixture)

        let fromSelf = await provider.callees(of: root, file: fixture.url("Chain.java"))
        let fromOther = await provider.callees(of: root, file: fixture.url("Use.java"))
        XCTAssertEqual(fromSelf.map(\.displayName), ["Chain.local()", "Helper.help(int)"])
        XCTAssertEqual(fromOther.map(\.displayName), fromSelf.map(\.displayName))

        let location = await provider.location(of: root, file: fixture.url("Use.java"))
        let found = try XCTUnwrap(location)
        XCTAssertEqual(found.url?.lastPathComponent, "Chain.java")
        XCTAssertEqual(found.range.start.line, 1)
    }

    /// An unsaved buffer is what the hierarchy reads, not the file on disk.
    func testLocationReadsTheOpenBufferOverTheDisk() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Chain.java", "class Chain {\n    void €caller() { }\n}\n")
        let provider = try await makeProvider(fixture)
        let root = try await rootMethod(provider, fixture)
        let edited = "class Chain {\n\n\n    void caller() { }\n}\n"
        await provider.setOpenBufferLookup { url in url.lastPathComponent == "Chain.java" ? edited : nil }
        let location = await provider.location(of: root, file: fixture.url("Chain.java"))
        let found = try XCTUnwrap(location)
        XCTAssertEqual(found.range.start.line, 3, "the buffer moved the method down two lines")
        XCTAssertEqual(found.range.start.column, 9)
    }
}
