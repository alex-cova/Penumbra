import XCTest
@testable import JavaIntelligence

final class JavaTypeResolverTests: XCTestCase {
    private func tempShardURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).idx")
    }

    private func makeIndex(withStubs stubs: [JavaClassStub]) async throws -> JavaIndex {
        let url = tempShardURL()
        try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: url)
        let reader = try JavaIndexShardReader(url: url)
        let index = JavaIndex()
        await index.setSources([.init(precedence: 3, reader: reader)])
        return index
    }

    private func stub(_ qualifiedName: String, innerTypeNames: [String] = [], superclass: String? = nil) -> JavaClassStub {
        let simple = String(qualifiedName.split(separator: ".").last!)
        let pkg = qualifiedName.contains(".") ? qualifiedName.components(separatedBy: ".").dropLast().joined(separator: ".") : ""
        return JavaClassStub(
            binaryName: qualifiedName, qualifiedName: qualifiedName, simpleName: simple, packageName: pkg,
            kind: .classKind, modifiers: [.publicFlag],
            superclass: superclass.map { JavaTypeRef.classType(qualifiedName: $0, arguments: [], outer: nil) },
            innerTypeNames: innerTypeNames, origin: .jdkModule("test")
        )
    }

    func testTypeParameterInScopeResolvesToTypeVariable() async throws {
        let index = try await makeIndex(withStubs: [])
        let context = JavaResolutionContext(packageName: "", imports: [], typeParameterNames: ["T"])
        let resolved = await JavaTypeResolver.resolve(.unresolved(simpleName: "T", arguments: []), context: context, index: index)
        XCTAssertEqual(resolved, .typeVariable(name: "T"))
    }

    func testNestedTypeOfEnclosingClassResolves() async throws {
        let outer = stub("com.example.Outer", innerTypeNames: ["com.example.Outer.Inner"])
        let inner = stub("com.example.Outer.Inner")
        let index = try await makeIndex(withStubs: [outer, inner])
        let context = JavaResolutionContext(packageName: "com.example", imports: [], enclosingTypeQualifiedNames: ["com.example.Outer"])
        let resolved = await JavaTypeResolver.resolve(.unresolved(simpleName: "Inner", arguments: []), context: context, index: index)
        XCTAssertEqual(resolved.erasedQualifiedName, "com.example.Outer.Inner")
    }

    func testSingleTypeImportResolves() async throws {
        let index = try await makeIndex(withStubs: [])
        let context = JavaResolutionContext(
            packageName: "com.example",
            imports: [JavaImportDeclaration(qualifiedName: "java.util.List", isStatic: false, isOnDemand: false)]
        )
        let resolved = await JavaTypeResolver.resolve(.unresolved(simpleName: "List", arguments: []), context: context, index: index)
        XCTAssertEqual(resolved.erasedQualifiedName, "java.util.List")
    }

    func testSamePackageResolvesWhenClassExistsInIndex() async throws {
        let index = try await makeIndex(withStubs: [stub("com.example.Helper")])
        let context = JavaResolutionContext(packageName: "com.example", imports: [])
        let resolved = await JavaTypeResolver.resolve(.unresolved(simpleName: "Helper", arguments: []), context: context, index: index)
        XCTAssertEqual(resolved.erasedQualifiedName, "com.example.Helper")
    }

    func testSamePackageCandidateNotUsedWhenClassDoesNotExist() async throws {
        let index = try await makeIndex(withStubs: [])
        let context = JavaResolutionContext(packageName: "com.example", imports: [])
        let resolved = await JavaTypeResolver.resolve(.unresolved(simpleName: "Ghost", arguments: []), context: context, index: index)
        // Falls through every step and stays unresolved, since no import/package/java.lang candidate exists.
        XCTAssertEqual(resolved, .unresolved(simpleName: "Ghost", arguments: []))
    }

    func testOnDemandImportResolvesSingleProvider() async throws {
        let index = try await makeIndex(withStubs: [stub("java.util.List")])
        let context = JavaResolutionContext(
            packageName: "",
            imports: [
                JavaImportDeclaration(qualifiedName: "java.io", isStatic: false, isOnDemand: true),
                JavaImportDeclaration(qualifiedName: "java.util", isStatic: false, isOnDemand: true)
            ]
        )
        let resolved = await JavaTypeResolver.resolve(.unresolved(simpleName: "List", arguments: []), context: context, index: index)
        XCTAssertEqual(resolved.erasedQualifiedName, "java.util.List")
    }

    /// F-05: when two on-demand imports both provide the name the reference is ambiguous
    /// (JLS 6.5.2) — it stays unresolved instead of silently picking the first match.
    func testAmbiguousOnDemandImportsStayUnresolved() async throws {
        let index = try await makeIndex(withStubs: [stub("java.util.List"), stub("java.awt.List")])
        let context = JavaResolutionContext(
            packageName: "",
            imports: [
                JavaImportDeclaration(qualifiedName: "java.util", isStatic: false, isOnDemand: true),
                JavaImportDeclaration(qualifiedName: "java.awt", isStatic: false, isOnDemand: true)
            ]
        )
        let resolved = await JavaTypeResolver.resolve(.unresolved(simpleName: "List", arguments: []), context: context, index: index)
        XCTAssertEqual(resolved, .unresolved(simpleName: "List", arguments: []))
    }

    /// F-05: a member type inherited from a supertype shadows imports (JLS 6.5.2 member types
    /// resolve before any import), even though the supertype walk runs after the declared-nested
    /// probe for performance.
    func testInheritedNestedTypeBeatsSingleTypeImport() async throws {
        let base = stub("com.example.Base", innerTypeNames: ["com.example.Base.Nested"])
        let nested = stub("com.example.Base.Nested")
        let outer = stub("com.example.Outer", superclass: "com.example.Base")
        let imported = stub("com.other.Nested")
        let index = try await makeIndex(withStubs: [base, nested, outer, imported])
        let context = JavaResolutionContext(
            packageName: "com.example",
            imports: [JavaImportDeclaration(qualifiedName: "com.other.Nested", isStatic: false, isOnDemand: false)],
            enclosingTypeQualifiedNames: ["com.example.Outer"]
        )
        let resolved = await JavaTypeResolver.resolve(.unresolved(simpleName: "Nested", arguments: []), context: context, index: index)
        XCTAssertEqual(resolved.erasedQualifiedName, "com.example.Base.Nested")
    }

    /// F-05: the inherited member type also beats the same-package candidate and `java.lang`.
    func testInheritedNestedTypeBeatsSamePackageAndJavaLang() async throws {
        let base = stub("com.example.Base", innerTypeNames: ["com.example.Base.Helper"])
        let nested = stub("com.example.Base.Helper")
        let outer = stub("com.example.Outer", superclass: "com.example.Base")
        let samePackage = stub("com.example.Helper")
        let index = try await makeIndex(withStubs: [base, nested, outer, samePackage])
        let context = JavaResolutionContext(
            packageName: "com.example",
            imports: [],
            enclosingTypeQualifiedNames: ["com.example.Outer"]
        )
        let resolved = await JavaTypeResolver.resolve(.unresolved(simpleName: "Helper", arguments: []), context: context, index: index)
        XCTAssertEqual(resolved.erasedQualifiedName, "com.example.Base.Helper")
    }

    func testJavaLangFallbackResolves() async throws {
        let index = try await makeIndex(withStubs: [stub("java.lang.String")])
        let context = JavaResolutionContext(packageName: "com.example", imports: [])
        let resolved = await JavaTypeResolver.resolve(.unresolved(simpleName: "String", arguments: []), context: context, index: index)
        XCTAssertEqual(resolved.erasedQualifiedName, "java.lang.String")
    }

    func testStaticImportOnDemandIsNeverUsedForTypeResolution() async throws {
        // A static on-demand import (import static java.lang.Math.*;) contributes members, not
        // types -- it must never be treated as a type-search prefix.
        let index = try await makeIndex(withStubs: [stub("java.lang.Math")])
        let context = JavaResolutionContext(
            packageName: "",
            imports: [JavaImportDeclaration(qualifiedName: "java.lang.Math", isStatic: true, isOnDemand: true)]
        )
        let resolved = await JavaTypeResolver.resolve(.unresolved(simpleName: "Foo", arguments: []), context: context, index: index)
        XCTAssertEqual(resolved, .unresolved(simpleName: "Foo", arguments: []))
    }

    func testResolutionOrderPrefersImportOverSamePackage() async throws {
        // Same simple name exists both as an explicit import target and (hypothetically) in the
        // same package; the import must win per the documented resolution order.
        let index = try await makeIndex(withStubs: [stub("com.example.Foo"), stub("other.pkg.Foo")])
        let context = JavaResolutionContext(
            packageName: "com.example",
            imports: [JavaImportDeclaration(qualifiedName: "other.pkg.Foo", isStatic: false, isOnDemand: false)]
        )
        let resolved = await JavaTypeResolver.resolve(.unresolved(simpleName: "Foo", arguments: []), context: context, index: index)
        XCTAssertEqual(resolved.erasedQualifiedName, "other.pkg.Foo")
    }

    func testGenericArgumentsAreResolvedRecursively() async throws {
        let index = try await makeIndex(withStubs: [stub("com.example.Foo")])
        let context = JavaResolutionContext(packageName: "com.example", imports: [])
        let type = JavaTypeRef.classType(
            qualifiedName: "java.util.List",
            arguments: [.type(.unresolved(simpleName: "Foo", arguments: []))],
            outer: nil
        )
        let resolved = await JavaTypeResolver.resolve(type, context: context, index: index)
        guard case .classType(_, let args, _) = resolved, case .type(let arg) = args.first else {
            return XCTFail("expected resolved generic argument")
        }
        XCTAssertEqual(arg.erasedQualifiedName, "com.example.Foo")
    }

    func testArrayElementTypeIsResolved() async throws {
        let index = try await makeIndex(withStubs: [stub("com.example.Foo")])
        let context = JavaResolutionContext(packageName: "com.example", imports: [])
        let resolved = await JavaTypeResolver.resolve(.array(element: .unresolved(simpleName: "Foo", arguments: [])), context: context, index: index)
        guard case .array(let element) = resolved else { return XCTFail("expected array") }
        XCTAssertEqual(element.erasedQualifiedName, "com.example.Foo")
    }

    func testWildcardBoundIsResolved() async throws {
        let index = try await makeIndex(withStubs: [stub("com.example.Foo")])
        let context = JavaResolutionContext(packageName: "com.example", imports: [])
        let resolved = await JavaTypeResolver.resolve(.wildcard(bound: .extends(.unresolved(simpleName: "Foo", arguments: []))), context: context, index: index)
        guard case .wildcard(.extends(let bound)) = resolved else { return XCTFail("expected wildcard extends bound") }
        XCTAssertEqual(bound.erasedQualifiedName, "com.example.Foo")
    }

    func testPrimitivesAndVoidPassThroughUnchanged() async throws {
        let index = try await makeIndex(withStubs: [])
        let context = JavaResolutionContext(packageName: "", imports: [])
        let intResolved = await JavaTypeResolver.resolve(.primitive(.int), context: context, index: index)
        let voidResolved = await JavaTypeResolver.resolve(.void, context: context, index: index)
        XCTAssertEqual(intResolved, .primitive(.int))
        XCTAssertEqual(voidResolved, .void)
    }
}
