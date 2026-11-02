import EditorIntelligence
import XCTest
@testable import JavaIntelligence

/// Callers of a decompiled class's methods, read from bytecode. The classes are compiled from
/// `Fixtures/JavaBytecode/src` (`demo.Shape`, `Circle`, `Square`, `Report`).
final class JavaBytecodeCallersTests: XCTestCase {
    private var fixtures: URL {
        Bundle.module.resourceURL!.appendingPathComponent("JavaBytecode", isDirectory: true)
    }
    private var classes: URL { fixtures.appendingPathComponent("classes", isDirectory: true) }
    private var jar: URL { fixtures.appendingPathComponent("demo.jar") }
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bytecode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func method(_ owner: String, _ name: String, _ descriptor: String) -> JavaBytecodeTarget {
        JavaBytecodeTarget(kind: .method, owner: "demo/\(owner)", name: name, descriptor: descriptor)
    }

    private func names(_ targets: [JavaBytecodeTarget]) -> [String] {
        targets.map { "\($0.owner.replacingOccurrences(of: "demo/", with: "")).\($0.name)" }
    }

    // MARK: Reader

    func testReaderListsMembersAndTheReferencesOfEachMethod() throws {
        let data = try Data(contentsOf: classes.appendingPathComponent("demo/Report.class"))
        let parsed = try XCTUnwrap(JavaBytecodeReader.parse(data, includeBodies: true))
        XCTAssertEqual(parsed.name, "demo/Report")
        let total = try XCTUnwrap(parsed.methods.firstIndex { $0.name == "total" })
        XCTAssertTrue(parsed.references[total].contains(.method(owner: "demo/Shape", name: "area", descriptor: "()D")))
        // A lambda body is its own synthetic method; the method reference is a handle on `lazy`'s peer.
        XCTAssertTrue(parsed.methods.contains { $0.name.hasPrefix("lambda$lazy$") })
        let reference = try XCTUnwrap(parsed.methods.firstIndex { $0.name == "reference" })
        XCTAssertTrue(parsed.references[reference].contains(.method(owner: "demo/Circle", name: "area", descriptor: "()D")))
    }

    func testReaderRejectsTruncatedAndForeignBytes() throws {
        let data = try Data(contentsOf: classes.appendingPathComponent("demo/Report.class"))
        XCTAssertNil(JavaBytecodeReader.parse(Data("hello".utf8), includeBodies: true))
        for cut in stride(from: 4, to: data.count, by: 37) {
            _ = JavaBytecodeReader.parse(data.prefix(cut), includeBodies: true)
        }
    }

    // MARK: Search

    func testCallersOfAnInterfaceMethodIncludeCallsThroughImplementations() {
        let callers = JavaBytecodeCallerSearch.callers(of: method("Shape", "area", "()D"), in: .directory(classes))
        // total (interface call), circle (Circle.area), lazy (the lambda body's Square.area), reference
        // (Circle::area) and Square.describe (its own area() call).
        XCTAssertEqual(names(callers), ["Report.circle", "Report.lazy", "Report.reference", "Report.total", "Square.describe"])
    }

    func testCallersOfAnOverrideIncludeTheSuperTypeButNotASibling() {
        let callers = JavaBytecodeCallerSearch.callers(of: method("Circle", "area", "()D"), in: .directory(classes))
        XCTAssertEqual(names(callers), ["Report.circle", "Report.reference", "Report.total"])
        XCTAssertFalse(names(callers).contains("Report.lazy"), "Square.area is a sibling, not a call to Circle.area")
    }

    func testOverloadsAreToldApartByDescriptor() {
        let one = JavaBytecodeCallerSearch.callers(
            of: method("Square", "describe", "(Ljava/lang/String;)Ljava/lang/String;"), in: .directory(classes)
        )
        XCTAssertEqual(names(one), ["Report.names"])
        let two = JavaBytecodeCallerSearch.callers(
            of: method("Square", "describe", "(Ljava/lang/String;I)Ljava/lang/String;"), in: .directory(classes)
        )
        XCTAssertEqual(names(two), ["Square.describe"])
        XCTAssertEqual(two.first?.descriptor, "(Ljava/lang/String;)Ljava/lang/String;")
    }

    func testCallersOfAFieldAreItsReadersAndWriters() {
        let field = JavaBytecodeTarget(kind: .field, owner: "demo/Square", name: "created", descriptor: "I")
        let callers = JavaBytecodeCallerSearch.callers(of: field, in: .directory(classes))
        XCTAssertEqual(names(callers), ["Report.names", "Square.<init>"])
    }

    func testCallersOfAClassAreWhoeverUsesIt() {
        let callers = JavaBytecodeCallerSearch.callers(of: .init(kind: .type, owner: "demo/Circle"), in: .directory(classes))
        XCTAssertEqual(names(callers), ["Report.circle", "Report.reference"])
    }

    func testCalleesFoldTheLambdasWrittenInsideAMethod() {
        let callees = JavaBytecodeCallerSearch.callees(of: method("Report", "lazy", "(Ldemo/Square;)Ljava/util/function/Supplier;"), in: .directory(classes))
        XCTAssertTrue(callees.contains(method("Square", "area", "()D")))
        XCTAssertFalse(callees.contains { $0.name.hasPrefix("lambda$") })
    }

    func testAJarIsSearchedLikeADirectory() {
        let callers = JavaBytecodeCallerSearch.callers(of: method("Shape", "area", "()D"), in: .archive(jar))
        XCTAssertEqual(names(callers).count, 5)
    }

    // MARK: Containers

    func testAClassFileBelongsToTheDirectoryThatRootsItsPackage() throws {
        let file = classes.appendingPathComponent("demo/Report.class")
        let data = try Data(contentsOf: file)
        XCTAssertEqual(
            JavaClassContainer.container(forClassFile: file, archives: [], classData: data),
            .directory(classes.standardizedFileURL)
        )
    }

    func testACopyUnderTheCacheBelongsToTheJarItCameOutOf() throws {
        let cacheRoot = scratch.appendingPathComponent("cache")
        let copy = try XCTUnwrap(JavaAttachedSources.extractResource(entry: "demo/Report.class", from: jar, cacheRoot: cacheRoot))
        XCTAssertEqual(
            JavaClassContainer.container(forClassFile: copy, archives: [jar], classData: nil),
            .archive(jar.standardizedFileURL)
        )
        XCTAssertNil(JavaClassContainer.container(forClassFile: copy, archives: [], classData: nil))
    }

    // MARK: Caret → target

    private func decompiled(_ name: String) throws -> (text: String, container: JavaClassContainer) {
        let data = try Data(contentsOf: classes.appendingPathComponent("demo/\(name).class"))
        return (try XCTUnwrap(JavaClassFileDecompiler.decompile(data)), .directory(classes))
    }

    private func offset(of needle: String, in text: String, occurrence: Int = 0) throws -> Int {
        var searchRange = text.startIndex..<text.endIndex
        var found: Range<String.Index>?
        for _ in 0...occurrence {
            found = text.range(of: needle, range: searchRange)
            searchRange = (found?.upperBound ?? text.endIndex)..<text.endIndex
        }
        return text.utf16.distance(from: text.utf16.startIndex, to: try XCTUnwrap(found).lowerBound)
    }

    func testTheCaretInAMethodNamesItsDescriptor() throws {
        let (text, container) = try decompiled("Report")
        let locator = JavaBytecodeSymbolLocator(source: text, thisName: "demo/Report", container: container)
        let caret = try offset(of: "var2 = var2 +", in: text)
        XCTAssertEqual(locator.target(atUTF16Offset: caret), method("Report", "total", "(Ljava/util/List;)D"))
    }

    func testOverloadsInTheTextResolveToTheirOwnDescriptors() throws {
        let (text, container) = try decompiled("Square")
        let locator = JavaBytecodeSymbolLocator(source: text, thisName: "demo/Square", container: container)
        let two = try offset(of: "describe", in: text, occurrence: 0)
        let one = try offset(of: "describe", in: text, occurrence: 1)
        let targets = [locator.target(atUTF16Offset: two), locator.target(atUTF16Offset: one)].compactMap { $0?.descriptor }
        XCTAssertEqual(Set(targets), [
            "(Ljava/lang/String;I)Ljava/lang/String;", "(Ljava/lang/String;)Ljava/lang/String;"
        ])
        XCTAssertEqual(targets.count, 2)
    }

    func testAConstructorAndAFieldAndTheClassResolve() throws {
        let (text, container) = try decompiled("Square")
        let locator = JavaBytecodeSymbolLocator(source: text, thisName: "demo/Square", container: container)
        let constructor = try offset(of: "Square.created = ", in: text)
        XCTAssertEqual(locator.target(atUTF16Offset: constructor)?.name, "<init>")
        let field = try offset(of: "created", in: text)
        XCTAssertEqual(
            locator.target(atUTF16Offset: field),
            JavaBytecodeTarget(kind: .field, owner: "demo/Square", name: "created", descriptor: "I")
        )
        let className = try offset(of: "Square", in: text, occurrence: 0)
        XCTAssertEqual(locator.target(atUTF16Offset: className)?.kind, .type)
    }

    func testADeclarationIsFoundByItsBytecodeIdentity() throws {
        let (text, container) = try decompiled("Square")
        let locator = JavaBytecodeSymbolLocator(source: text, thisName: "demo/Square", container: container)
        let target = method("Square", "describe", "(Ljava/lang/String;)Ljava/lang/String;")
        let range = try XCTUnwrap(locator.nameRange(of: target))
        let bytes = Array(text.utf8)
        XCTAssertEqual(String(decoding: bytes[range], as: UTF8.self), "describe")
        // And it is the one-argument overload: its body calls the two-argument one.
        let after = String(decoding: bytes[range.upperBound...], as: UTF8.self)
        XCTAssertTrue(after.hasPrefix("(String str)"), after)
    }

    // MARK: Provider

    private final class NoFallback: CallHierarchyProviding {
        func rootItem(source: String, fileURL: URL?, utf16Offset: Int) async -> HierarchyItem? { nil }
        func callers(of item: HierarchyItem, file: URL?) async -> [HierarchyItem] { [] }
        func callees(of item: HierarchyItem, file: URL?) async -> [HierarchyItem] { [] }
        func location(of item: HierarchyItem, file: URL?) async -> HierarchyLocation? { nil }
    }

    func testTheProviderBuildsATreeFromADecompiledTabAndOpensACaller() async throws {
        let provider = JavaBytecodeCallHierarchyProvider(fallback: NoFallback(), cacheRoot: scratch.appendingPathComponent("cache"))
        let (text, _) = try decompiled("Circle")
        let file = classes.appendingPathComponent("demo/Circle.class")
        let caret = try offset(of: "3.141592653589793", in: text)
        let rootItem = await provider.rootItem(source: text, fileURL: file, utf16Offset: caret)
        let root = try XCTUnwrap(rootItem)
        XCTAssertEqual(root.name, "Circle.area()")
        XCTAssertEqual(root.detail, "demo")

        let callers = await provider.callers(of: root, file: file)
        XCTAssertEqual(callers.map(\.name), ["Report.circle()", "Report.reference(Circle)", "Report.total(List)"])
        // Expanding a caller asks who calls it, in the same container.
        let total = try XCTUnwrap(callers.last)
        XCTAssertTrue(total.id.hasPrefix(root.id + " > "))
        let deeper = await provider.callers(of: total, file: file)
        XCTAssertTrue(deeper.isEmpty)

        let found = await provider.location(of: total, file: file)
        let location = try XCTUnwrap(found)
        XCTAssertEqual(location.url?.standardizedFileURL, classes.appendingPathComponent("demo/Report.class").standardizedFileURL)
        XCTAssertGreaterThan(location.range.start.line, 0, "the range points at total's declaration, not the top")
    }

    func testAClassFromAnOpenedJarFindsCallersInsideThatJar() async throws {
        let cache = scratch.appendingPathComponent("cache")
        let provider = JavaBytecodeCallHierarchyProvider(fallback: NoFallback(), cacheRoot: cache)
        provider.setArchives([jar])
        let copy = try XCTUnwrap(JavaAttachedSources.extractResource(entry: "demo/Shape.class", from: jar, cacheRoot: cache))
        let text = try XCTUnwrap(JavaClassFileDecompiler.decompile(contentsOf: copy))
        let caret = try offset(of: "area", in: text)
        let rootItem = await provider.rootItem(source: text, fileURL: copy, utf16Offset: caret)
        let root = try XCTUnwrap(rootItem)
        let callers = await provider.callers(of: root, file: copy)
        XCTAssertEqual(callers.count, 5)
        // The caller's class opens as a copy out of the same jar.
        let first = try XCTUnwrap(callers.first)
        let opened = await provider.location(of: first, file: copy)
        let location = try XCTUnwrap(opened)
        XCTAssertTrue(JavaAttachedSources.isInCache(try XCTUnwrap(location.url)))
    }

    func testOtherFilesGoToTheSourceBasedProvider() async throws {
        final class Recording: CallHierarchyProviding, @unchecked Sendable {
            var asked = false
            func rootItem(source: String, fileURL: URL?, utf16Offset: Int) async -> HierarchyItem? { asked = true; return nil }
            func callers(of item: HierarchyItem, file: URL?) async -> [HierarchyItem] { [] }
            func callees(of item: HierarchyItem, file: URL?) async -> [HierarchyItem] { [] }
            func location(of item: HierarchyItem, file: URL?) async -> HierarchyLocation? { nil }
        }
        let fallback = Recording()
        let provider = JavaBytecodeCallHierarchyProvider(fallback: fallback, cacheRoot: scratch)
        _ = await provider.rootItem(source: "class A {}", fileURL: scratch.appendingPathComponent("A.java"), utf16Offset: 0)
        XCTAssertTrue(fallback.asked)
    }
}
