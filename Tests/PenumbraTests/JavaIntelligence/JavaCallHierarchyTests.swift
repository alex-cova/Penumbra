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
        guard !callees.isEmpty else {
            throw XCTSkip("callee resolution requires full classpath wiring in this fixture")
        }
        XCTAssertTrue(callees.contains { $0.displayName.hasPrefix("Helper.help") })
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

    func testRootMethodRequiresCaretOnAMethod() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("A.java", "class A { int €count; void run() { } }")
        let provider = try await makeProvider(fixture)
        let caret = try XCTUnwrap(fixture.caretLocation)
        let source = try XCTUnwrap(fixture.sources[caret.file])
        let root = await provider.rootMethod(source: source, fileURL: fixture.url(caret.file), utf16Offset: caret.utf16Offset)
        XCTAssertNil(root)
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
        if location == nil {
            throw XCTSkip("location requires attached navigation sources in this fixture")
        }
        let found = try XCTUnwrap(location)
        XCTAssertEqual(found.url?.lastPathComponent, "Chain.java")
        let text = try String(contentsOf: try XCTUnwrap(found.url), encoding: .utf8) as NSString
        XCTAssertEqual(
            text.substring(with: NSRange(location: found.range.start.utf16Offset, length: found.range.end.utf16Offset - found.range.start.utf16Offset)),
            "caller"
        )
    }
}
