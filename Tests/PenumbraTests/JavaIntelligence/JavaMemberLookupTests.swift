import XCTest
@testable import JavaIntelligence

final class JavaMemberLookupTests: XCTestCase {
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

    private func classType(_ name: String, args: [JavaTypeArgument] = []) -> JavaTypeRef {
        .classType(qualifiedName: name, arguments: args, outer: nil)
    }

    private func defaultContext(package: String = "com.example", topLevel: String? = nil) -> JavaResolutionContext {
        JavaResolutionContext(packageName: package, imports: [], enclosingTypeQualifiedNames: topLevel.map { [$0] } ?? [])
    }

    // MARK: - Basic own-class members

    func testOwnClassMembersAreReturned() async throws {
        let foo = JavaClassStub(
            binaryName: "Foo", qualifiedName: "Foo", simpleName: "Foo", packageName: "",
            kind: .classKind, modifiers: [.publicFlag],
            fields: [JavaFieldStub(name: "x", type: .primitive(.int), modifiers: [.publicFlag])],
            methods: [JavaMethodStub(name: "bar", parameters: [], returnType: .void, modifiers: [.publicFlag])],
            origin: .jdkModule("test")
        )
        let index = try await makeIndex(withStubs: [foo])
        let members = await JavaMemberLookup.members(of: classType("Foo"), mode: .instance, context: defaultContext(package: ""), index: index)
        XCTAssertTrue(members.contains { $0.name == "x" })
        XCTAssertTrue(members.contains { $0.name == "bar" })
    }

    // MARK: - Inheritance

    func testInheritedMembersFromSuperclassAndInterface() async throws {
        let object = objectStub()
        let base = JavaClassStub(
            binaryName: "Base", qualifiedName: "Base", simpleName: "Base", packageName: "",
            kind: .classKind, modifiers: [.publicFlag],
            fields: [JavaFieldStub(name: "baseField", type: .primitive(.int), modifiers: [.publicFlag])],
            origin: .jdkModule("test")
        )
        let iface = JavaClassStub(
            binaryName: "Greetable", qualifiedName: "Greetable", simpleName: "Greetable", packageName: "",
            kind: .interfaceKind, modifiers: [.publicFlag, .abstractFlag],
            methods: [JavaMethodStub(name: "greet", parameters: [], returnType: .void, modifiers: [.publicFlag, .abstractFlag])],
            origin: .jdkModule("test")
        )
        let sub = JavaClassStub(
            binaryName: "Sub", qualifiedName: "Sub", simpleName: "Sub", packageName: "",
            kind: .classKind, modifiers: [.publicFlag],
            superclass: classType("Base"), interfaces: [classType("Greetable")],
            methods: [JavaMethodStub(name: "subMethod", parameters: [], returnType: .void, modifiers: [.publicFlag])],
            origin: .jdkModule("test")
        )
        let index = try await makeIndex(withStubs: [object, base, iface, sub])
        let members = await JavaMemberLookup.members(of: classType("Sub"), mode: .instance, context: defaultContext(package: ""), index: index)
        let names = Set(members.map(\.name))
        XCTAssertTrue(names.contains("baseField"))
        XCTAssertTrue(names.contains("greet"))
        XCTAssertTrue(names.contains("subMethod"))
        XCTAssertTrue(names.contains("toString"), "should reach java.lang.Object transitively")
    }

    func testOverrideHidesSuperclassVersionByErasedSignature() async throws {
        let object = objectStub()
        let base = JavaClassStub(
            binaryName: "Base", qualifiedName: "Base", simpleName: "Base", packageName: "",
            kind: .classKind, modifiers: [.publicFlag],
            methods: [JavaMethodStub(name: "greet", parameters: [], returnType: classType("java.lang.Object"), modifiers: [.publicFlag])],
            origin: .jdkModule("test")
        )
        let sub = JavaClassStub(
            binaryName: "Sub", qualifiedName: "Sub", simpleName: "Sub", packageName: "",
            kind: .classKind, modifiers: [.publicFlag], superclass: classType("Base"),
            methods: [JavaMethodStub(name: "greet", parameters: [], returnType: classType("java.lang.String"), modifiers: [.publicFlag])],
            origin: .jdkModule("test")
        )
        let index = try await makeIndex(withStubs: [object, base, sub])
        let members = await JavaMemberLookup.members(of: classType("Sub"), mode: .instance, context: defaultContext(package: ""), index: index)
        let greets = members.filter { $0.name == "greet" }
        XCTAssertEqual(greets.count, 1, "override should hide the superclass version, not duplicate it")
        guard case .method(let method, let declaringClass) = greets.first else { return XCTFail() }
        XCTAssertEqual(declaringClass, "Sub", "the more-derived override should win")
        XCTAssertEqual(method.returnType.erasedQualifiedName, "java.lang.String")
    }

    func testOverloadsWithDifferentParametersAreNotDeduplicated() async throws {
        let foo = JavaClassStub(
            binaryName: "Foo", qualifiedName: "Foo", simpleName: "Foo", packageName: "",
            kind: .classKind, modifiers: [.publicFlag],
            methods: [
                JavaMethodStub(name: "add", parameters: [JavaParameterStub(name: "a", type: .primitive(.int))], returnType: .void, modifiers: [.publicFlag]),
                JavaMethodStub(name: "add", parameters: [JavaParameterStub(name: "a", type: classType("java.lang.String"))], returnType: .void, modifiers: [.publicFlag])
            ],
            origin: .jdkModule("test")
        )
        let index = try await makeIndex(withStubs: [foo])
        let members = await JavaMemberLookup.members(of: classType("Foo"), mode: .instance, context: defaultContext(package: ""), index: index)
        XCTAssertEqual(members.filter { $0.name == "add" }.count, 2)
    }

    // MARK: - Generic substitution

    func testGenericSubstitutionThroughInheritance() async throws {
        // interface Container<E> { E get(); }
        // class StringBox implements Container<String> { }
        let container = JavaClassStub(
            binaryName: "Container", qualifiedName: "Container", simpleName: "Container", packageName: "",
            kind: .interfaceKind, modifiers: [.publicFlag, .abstractFlag],
            typeParameters: [JavaTypeParameter(name: "E", bounds: [])],
            methods: [JavaMethodStub(name: "get", parameters: [], returnType: .typeVariable(name: "E"), modifiers: [.publicFlag, .abstractFlag])],
            origin: .jdkModule("test")
        )
        let stringBox = JavaClassStub(
            binaryName: "StringBox", qualifiedName: "StringBox", simpleName: "StringBox", packageName: "",
            kind: .classKind, modifiers: [.publicFlag],
            interfaces: [classType("Container", args: [.type(classType("java.lang.String"))])],
            origin: .jdkModule("test")
        )
        let index = try await makeIndex(withStubs: [objectStub(), container, stringBox])
        let members = await JavaMemberLookup.members(of: classType("StringBox"), mode: .instance, context: defaultContext(package: ""), index: index)
        guard case .method(let get, _) = members.first(where: { $0.name == "get" }) else { return XCTFail("expected get()") }
        XCTAssertEqual(get.returnType.erasedQualifiedName, "java.lang.String", "E should be substituted with String")
    }

    func testGenericSubstitutionThroughTwoLevelsOfInheritance() async throws {
        // class GrandParent<A> { A value; }
        // class Parent<B> extends GrandParent<B> { }
        // class Child extends Parent<Integer> { }
        let grandParent = JavaClassStub(
            binaryName: "GrandParent", qualifiedName: "GrandParent", simpleName: "GrandParent", packageName: "",
            kind: .classKind, modifiers: [.publicFlag], typeParameters: [JavaTypeParameter(name: "A", bounds: [])],
            fields: [JavaFieldStub(name: "value", type: .typeVariable(name: "A"), modifiers: [.publicFlag])],
            origin: .jdkModule("test")
        )
        let parent = JavaClassStub(
            binaryName: "Parent", qualifiedName: "Parent", simpleName: "Parent", packageName: "",
            kind: .classKind, modifiers: [.publicFlag], typeParameters: [JavaTypeParameter(name: "B", bounds: [])],
            superclass: classType("GrandParent", args: [.type(.typeVariable(name: "B"))]),
            origin: .jdkModule("test")
        )
        let child = JavaClassStub(
            binaryName: "Child", qualifiedName: "Child", simpleName: "Child", packageName: "",
            kind: .classKind, modifiers: [.publicFlag],
            superclass: classType("Parent", args: [.type(classType("java.lang.Integer"))]),
            origin: .jdkModule("test")
        )
        let index = try await makeIndex(withStubs: [objectStub(), grandParent, parent, child])
        let members = await JavaMemberLookup.members(of: classType("Child"), mode: .instance, context: defaultContext(package: ""), index: index)
        guard case .field(let value, _) = members.first(where: { $0.name == "value" }) else { return XCTFail("expected value field") }
        XCTAssertEqual(value.type.erasedQualifiedName, "java.lang.Integer")
    }

    // MARK: - Access control

    func testPrivateMemberHiddenFromOtherTopLevelType() async throws {
        let foo = JavaClassStub(
            binaryName: "Foo", qualifiedName: "Foo", simpleName: "Foo", packageName: "",
            kind: .classKind, modifiers: [.publicFlag],
            fields: [JavaFieldStub(name: "secret", type: .primitive(.int), modifiers: [.privateFlag])],
            origin: .jdkModule("test")
        )
        let index = try await makeIndex(withStubs: [foo])
        let membersFromOutside = await JavaMemberLookup.members(of: classType("Foo"), mode: .instance, context: defaultContext(package: "", topLevel: "Bar"), index: index)
        XCTAssertFalse(membersFromOutside.contains { $0.name == "secret" })
    }

    func testPrivateMemberVisibleWithinSameTopLevelType() async throws {
        // class Foo { private int secret; class Inner {} } -- Inner (nested in Foo) can see Foo's private members.
        let foo = JavaClassStub(
            binaryName: "Foo", qualifiedName: "Foo", simpleName: "Foo", packageName: "",
            kind: .classKind, modifiers: [.publicFlag],
            fields: [JavaFieldStub(name: "secret", type: .primitive(.int), modifiers: [.privateFlag])],
            innerTypeNames: ["Foo.Inner"], origin: .jdkModule("test")
        )
        let index = try await makeIndex(withStubs: [foo])
        let context = JavaResolutionContext(packageName: "", imports: [], enclosingTypeQualifiedNames: ["Foo.Inner", "Foo"])
        let members = await JavaMemberLookup.members(of: classType("Foo"), mode: .instance, context: context, index: index)
        XCTAssertTrue(members.contains { $0.name == "secret" })
    }

    func testPackagePrivateMemberVisibleOnlyInSamePackage() async throws {
        let foo = JavaClassStub(
            binaryName: "com.a.Foo", qualifiedName: "com.a.Foo", simpleName: "Foo", packageName: "com.a",
            kind: .classKind, modifiers: [.publicFlag],
            fields: [JavaFieldStub(name: "packageField", type: .primitive(.int), modifiers: [])],
            origin: .jdkModule("test")
        )
        let index = try await makeIndex(withStubs: [foo])
        let samePackageMembers = await JavaMemberLookup.members(of: classType("com.a.Foo"), mode: .instance, context: defaultContext(package: "com.a"), index: index)
        let otherPackageMembers = await JavaMemberLookup.members(of: classType("com.a.Foo"), mode: .instance, context: defaultContext(package: "com.b"), index: index)
        XCTAssertTrue(samePackageMembers.contains { $0.name == "packageField" })
        XCTAssertFalse(otherPackageMembers.contains { $0.name == "packageField" })
    }

    func testProtectedMemberVisibleInSubclassAcrossPackages() async throws {
        let base = JavaClassStub(
            binaryName: "com.a.Base", qualifiedName: "com.a.Base", simpleName: "Base", packageName: "com.a",
            kind: .classKind, modifiers: [.publicFlag],
            fields: [JavaFieldStub(name: "protectedField", type: .primitive(.int), modifiers: [.protectedFlag])],
            origin: .jdkModule("test")
        )
        let sub = JavaClassStub(
            binaryName: "com.b.Sub", qualifiedName: "com.b.Sub", simpleName: "Sub", packageName: "com.b",
            kind: .classKind, modifiers: [.publicFlag], superclass: classType("com.a.Base"),
            origin: .jdkModule("test")
        )
        let index = try await makeIndex(withStubs: [objectStub(), base, sub])

        let fromSubclass = await JavaMemberLookup.members(of: classType("com.b.Sub"), mode: .instance, context: defaultContext(package: "com.b", topLevel: "com.b.Sub"), index: index)
        XCTAssertTrue(fromSubclass.contains { $0.name == "protectedField" })

        let unrelated = JavaClassStub(
            binaryName: "com.c.Unrelated", qualifiedName: "com.c.Unrelated", simpleName: "Unrelated", packageName: "com.c",
            kind: .classKind, modifiers: [.publicFlag], origin: .jdkModule("test")
        )
        let index2 = try await makeIndex(withStubs: [objectStub(), base, unrelated])
        let fromUnrelated = await JavaMemberLookup.members(of: classType("com.a.Base"), mode: .instance, context: defaultContext(package: "com.c", topLevel: "com.c.Unrelated"), index: index2)
        XCTAssertFalse(fromUnrelated.contains { $0.name == "protectedField" })
    }

    // MARK: - Static filtering

    func testStaticOnlyModeExcludesInstanceMembers() async throws {
        let foo = JavaClassStub(
            binaryName: "Foo", qualifiedName: "Foo", simpleName: "Foo", packageName: "",
            kind: .classKind, modifiers: [.publicFlag],
            fields: [
                JavaFieldStub(name: "staticField", type: .primitive(.int), modifiers: [.publicFlag, .staticFlag]),
                JavaFieldStub(name: "instanceField", type: .primitive(.int), modifiers: [.publicFlag])
            ],
            origin: .jdkModule("test")
        )
        let index = try await makeIndex(withStubs: [foo])
        let members = await JavaMemberLookup.members(of: classType("Foo"), mode: .staticOnly, context: defaultContext(package: ""), index: index)
        XCTAssertTrue(members.contains { $0.name == "staticField" })
        XCTAssertFalse(members.contains { $0.name == "instanceField" })
    }

    func testInstanceModeIncludesStaticMembersToo() async throws {
        let foo = JavaClassStub(
            binaryName: "Foo", qualifiedName: "Foo", simpleName: "Foo", packageName: "",
            kind: .classKind, modifiers: [.publicFlag],
            fields: [JavaFieldStub(name: "staticField", type: .primitive(.int), modifiers: [.publicFlag, .staticFlag])],
            origin: .jdkModule("test")
        )
        let index = try await makeIndex(withStubs: [foo])
        let members = await JavaMemberLookup.members(of: classType("Foo"), mode: .instance, context: defaultContext(package: ""), index: index)
        XCTAssertTrue(members.contains { $0.name == "staticField" })
    }

    // MARK: - Arrays

    func testArrayReceiverSynthesizesLengthAndClone() async throws {
        let index = try await makeIndex(withStubs: [])
        let members = await JavaMemberLookup.members(of: .array(element: .primitive(.int)), mode: .instance, context: defaultContext(package: ""), index: index)
        XCTAssertTrue(members.contains { $0.name == "length" })
        guard case .method(let clone, _) = members.first(where: { $0.name == "clone" }) else { return XCTFail("expected clone()") }
        guard case .array(let element) = clone.returnType else { return XCTFail("expected int[] clone() return") }
        XCTAssertEqual(element, .primitive(.int))
    }

    // MARK: - Enum constants

    func testEnumConstantsAppearAsStaticFields() async throws {
        let kind = JavaClassStub(
            binaryName: "Kind", qualifiedName: "Kind", simpleName: "Kind", packageName: "",
            kind: .enumKind, modifiers: [.publicFlag],
            fields: [JavaFieldStub(name: "FIRST", type: classType("Kind"), modifiers: [.publicFlag, .staticFlag, .finalFlag, .enumConstant])],
            origin: .jdkModule("test")
        )
        let index = try await makeIndex(withStubs: [objectStub(), kind])
        let members = await JavaMemberLookup.members(of: classType("Kind"), mode: .staticOnly, context: defaultContext(package: ""), index: index)
        XCTAssertTrue(members.contains { $0.name == "FIRST" })
    }

    // MARK: - Cycle safety

    func testCyclicInterfaceReferenceDoesNotHang() async throws {
        // Not valid Java, but the walker must not infinite-loop on malformed/edited-mid-typing data.
        let a = JavaClassStub(
            binaryName: "A", qualifiedName: "A", simpleName: "A", packageName: "", kind: .interfaceKind,
            modifiers: [.publicFlag, .abstractFlag], interfaces: [classType("B")], origin: .jdkModule("test")
        )
        let b = JavaClassStub(
            binaryName: "B", qualifiedName: "B", simpleName: "B", packageName: "", kind: .interfaceKind,
            modifiers: [.publicFlag, .abstractFlag], interfaces: [classType("A")], origin: .jdkModule("test")
        )
        let index = try await makeIndex(withStubs: [a, b])
        let members = await JavaMemberLookup.members(of: classType("A"), mode: .instance, context: defaultContext(package: ""), index: index)
        XCTAssertEqual(members, [])
    }

    // MARK: - Real JDK (opt-in)

    func testMemberLookupOnRealArrayListFindsInheritedListMembers() async throws {
        guard let found = TestJDK.discovered,
              let installation = ReleaseFileParser.parse(found.home),
              installation.hasCtSym else {
            throw XCTSkip("No JDK with ct.sym found on this machine")
        }
        let root = JDKCtSymRoot(installation: installation)
        let stubs = try root.readStubs()
        let shardURL = tempShardURL()
        defer { try? FileManager.default.removeItem(at: shardURL) }
        try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: shardURL)
        let reader = try JavaIndexShardReader(url: shardURL)
        let index = JavaIndex()
        await index.setSources([.init(precedence: 3, reader: reader)])

        // ArrayList<String> -- `get` should come back substituted to return String, not E, and
        // `add`/`size` should be reachable transitively through AbstractList/List/Collection.
        let type = classType("java.util.ArrayList", args: [.type(classType("java.lang.String"))])
        let members = await JavaMemberLookup.members(of: type, mode: .instance, context: defaultContext(package: ""), index: index)
        let names = Set(members.map(\.name))
        XCTAssertTrue(names.contains("add"))
        XCTAssertTrue(names.contains("size"))
        XCTAssertTrue(names.contains("isEmpty"))
        XCTAssertTrue(names.contains("toString"), "should reach java.lang.Object transitively")

        guard case .method(let get, _) = members.first(where: { $0.name == "get" }) else {
            return XCTFail("expected a get(int) method")
        }
        XCTAssertEqual(get.returnType.erasedQualifiedName, "java.lang.String", "E should be substituted with String")
    }

    func testMemberLookupOnRealJavaLangString() async throws {
        guard let found = TestJDK.discovered,
              let installation = ReleaseFileParser.parse(found.home),
              installation.hasCtSym else {
            throw XCTSkip("No JDK with ct.sym found on this machine")
        }
        let root = JDKCtSymRoot(installation: installation)
        let stubs = try root.readStubs()
        let shardURL = tempShardURL()
        defer { try? FileManager.default.removeItem(at: shardURL) }
        try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: shardURL)
        let reader = try JavaIndexShardReader(url: shardURL)
        let index = JavaIndex()
        await index.setSources([.init(precedence: 3, reader: reader)])

        let members = await JavaMemberLookup.members(of: classType("java.lang.String"), mode: .instance, context: defaultContext(package: ""), index: index)
        let names = Set(members.map(\.name))
        XCTAssertTrue(names.contains("length"))
        XCTAssertTrue(names.contains("isBlank"))
        XCTAssertTrue(names.contains("substring"))
        XCTAssertTrue(names.contains("hashCode"), "should reach java.lang.Object transitively")
    }

    private func objectStub() -> JavaClassStub {
        JavaClassStub(
            binaryName: "java.lang.Object", qualifiedName: "java.lang.Object", simpleName: "Object", packageName: "java.lang",
            kind: .classKind, modifiers: [.publicFlag],
            methods: [
                JavaMethodStub(name: "toString", parameters: [], returnType: classType("java.lang.String"), modifiers: [.publicFlag]),
                JavaMethodStub(name: "equals", parameters: [JavaParameterStub(name: "obj", type: classType("java.lang.Object"))], returnType: .primitive(.boolean), modifiers: [.publicFlag]),
                JavaMethodStub(name: "hashCode", parameters: [], returnType: .primitive(.int), modifiers: [.publicFlag])
            ],
            origin: .jdkModule("test")
        )
    }
}

extension JavaResolvedMember: Equatable {
    public static func == (lhs: JavaResolvedMember, rhs: JavaResolvedMember) -> Bool {
        lhs.name == rhs.name && lhs.declaringClass == rhs.declaringClass
    }
}
