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

    // MARK: - Interface fields

    /// A class field hides an interface field. A subinterface redeclaration hides the
    /// superinterface field. Two sibling interfaces leave the name out.
    func testInterfaceFieldHidingAndSiblingAmbiguity() async throws {
        func constant(_ owner: String, name: String, type: String) -> JavaClassStub {
            JavaClassStub(
                binaryName: owner, qualifiedName: owner, simpleName: owner, packageName: "",
                kind: .interfaceKind, modifiers: [.publicFlag, .abstractFlag],
                interfaces: owner == "SubI" ? [classType("SuperI")] : [],
                fields: [JavaFieldStub(name: name, type: classType(type), modifiers: [.publicFlag, .staticFlag, .finalFlag])],
                origin: .jdkModule("test")
            )
        }
        let superI = constant("SuperI", name: "VALUE", type: "java.lang.Number")
        let subI = constant("SubI", name: "VALUE", type: "java.lang.Integer")
        let left = constant("Left", name: "NAME", type: "java.lang.String")
        let right = constant("Right", name: "NAME", type: "java.lang.Integer")
        let host = JavaClassStub(
            binaryName: "Host", qualifiedName: "Host", simpleName: "Host", packageName: "",
            kind: .classKind, modifiers: [.publicFlag],
            interfaces: [classType("SubI"), classType("Left"), classType("Right")],
            fields: [JavaFieldStub(name: "NAME", type: classType("java.lang.Boolean"), modifiers: [.publicFlag])],
            origin: .jdkModule("test")
        )
        let both = JavaClassStub(
            binaryName: "Both", qualifiedName: "Both", simpleName: "Both", packageName: "",
            kind: .classKind, modifiers: [.publicFlag],
            interfaces: [classType("Left"), classType("Right")],
            origin: .jdkModule("test")
        )
        let index = try await makeIndex(withStubs: [objectStub(), superI, subI, left, right, host, both])
        let context = defaultContext(package: "")

        let throughSub = await JavaMemberLookup.members(of: classType("SubI"), mode: .instance, context: context, index: index)
        let value = throughSub.first { $0.name == "VALUE" }
        XCTAssertEqual(value?.declaringClass, "SubI")
        if case .field(let field, _) = value {
            XCTAssertEqual(field.type.erasedQualifiedName, "java.lang.Integer")
        } else {
            XCTFail("expected VALUE")
        }

        let throughHost = await JavaMemberLookup.members(of: classType("Host"), mode: .instance, context: context, index: index)
        let names = throughHost.filter { $0.name == "NAME" }
        XCTAssertEqual(names.count, 1)
        XCTAssertEqual(names.first?.declaringClass, "Host")
        XCTAssertEqual(throughHost.filter { $0.name == "VALUE" }.count, 1)

        let throughBoth = await JavaMemberLookup.members(of: classType("Both"), mode: .instance, context: context, index: index)
        XCTAssertFalse(throughBoth.contains { $0.name == "NAME" })
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

    // MARK: - Type-variable bounds (F-06)

    /// A value of type `T` offers its bound's members, not just `Object`'s.
    func testBoundedTypeVariableUsesBoundMembers() async throws {
        let base = JavaClassStub(
            binaryName: "Base", qualifiedName: "Base", simpleName: "Base", packageName: "",
            kind: .classKind, modifiers: [.publicFlag],
            methods: [JavaMethodStub(name: "baseOp", parameters: [], returnType: .void, modifiers: [.publicFlag])],
            origin: .jdkModule("test")
        )
        let index = try await makeIndex(withStubs: [objectStub(), base])
        let context = JavaResolutionContext(
            packageName: "", imports: [],
            typeParameterNames: ["T"], typeParameterBounds: ["T": [classType("Base")]]
        )
        let members = await JavaMemberLookup.members(
            of: .typeVariable(name: "T"), mode: .instance, context: context, index: index
        )
        XCTAssertTrue(members.contains { $0.name == "baseOp" }, "bound member missing: \(members.map(\.name))")
    }

    /// `T extends A & B` has what either bound offers (JLS 4.9), each shared signature once; javac accepts
    /// `a.intValue()` and `a.compareTo(b)` on `X extends Number & Comparable<X>`.
    func testIntersectionBoundUnitesMembers() async throws {
        func stub(_ name: String, methods: [String]) -> JavaClassStub {
            JavaClassStub(
                binaryName: name, qualifiedName: name, simpleName: name, packageName: "",
                kind: .classKind, modifiers: [.publicFlag],
                methods: methods.map {
                    JavaMethodStub(name: $0, parameters: [], returnType: .void, modifiers: [.publicFlag])
                },
                origin: .jdkModule("test")
            )
        }
        let index = try await makeIndex(withStubs: [objectStub(), stub("A", methods: ["shared", "onlyA"]), stub("B", methods: ["shared", "onlyB"])])
        let context = JavaResolutionContext(
            packageName: "", imports: [],
            typeParameterNames: ["T"], typeParameterBounds: ["T": [classType("A"), classType("B")]]
        )
        let members = await JavaMemberLookup.members(
            of: .typeVariable(name: "T"), mode: .instance, context: context, index: index
        )
        let names = Set(members.map(\.name))
        XCTAssertTrue(names.contains("shared"), "common member missing: \(names)")
        XCTAssertTrue(names.contains("onlyA"), "first bound's member missing: \(names)")
        XCTAssertTrue(names.contains("onlyB"), "second bound's member missing: \(names)")
        XCTAssertEqual(members.filter { $0.name == "shared" }.count, 1, "a shared signature is listed once")
    }

    /// An unbounded variable still falls back to `Object`.
    func testUnboundedTypeVariableFallsBackToObject() async throws {
        let index = try await makeIndex(withStubs: [objectStub()])
        let context = JavaResolutionContext(
            packageName: "", imports: [],
            typeParameterNames: ["T"], typeParameterBounds: [:]
        )
        let members = await JavaMemberLookup.members(
            of: .typeVariable(name: "T"), mode: .instance, context: context, index: index
        )
        XCTAssertTrue(members.contains { $0.name == "toString" })
    }

    // MARK: - Protected access (JLS 6.6.2.1)

    /// `Object.clone` and `Object.finalize`, plus a protected field, method and static of `Base`.
    private func protectedWorld() -> [JavaClassStub] {
        let object = JavaClassStub(
            binaryName: "java.lang.Object", qualifiedName: "java.lang.Object", simpleName: "Object", packageName: "java.lang",
            kind: .classKind, modifiers: [.publicFlag],
            methods: [
                JavaMethodStub(name: "toString", parameters: [], returnType: classType("java.lang.String"), modifiers: [.publicFlag]),
                JavaMethodStub(name: "clone", parameters: [], returnType: classType("java.lang.Object"), modifiers: [.protectedFlag]),
                JavaMethodStub(name: "finalize", parameters: [], returnType: .void, modifiers: [.protectedFlag])
            ],
            origin: .jdkModule("test")
        )
        let base = JavaClassStub(
            binaryName: "a.Base", qualifiedName: "a.Base", simpleName: "Base", packageName: "a",
            kind: .classKind, modifiers: [.publicFlag], superclass: classType("java.lang.Object"),
            fields: [
                JavaFieldStub(name: "secret", type: .primitive(.int), modifiers: [.protectedFlag]),
                JavaFieldStub(name: "STAT", type: .primitive(.int), modifiers: [.protectedFlag, .staticFlag])
            ],
            methods: [
                JavaMethodStub(name: "ping", parameters: [], returnType: .void, modifiers: [.protectedFlag]),
                JavaMethodStub(name: "pub", parameters: [], returnType: .void, modifiers: [.publicFlag]),
                JavaMethodStub(name: "Base", parameters: [], returnType: .void, modifiers: [.protectedFlag], isConstructor: true)
            ],
            origin: .jdkModule("test")
        )
        func type(_ name: String, package: String, superclass: String? = nil, kind: JavaTypeKind = .classKind) -> JavaClassStub {
            let simple = String(name.split(separator: ".").last!)
            return JavaClassStub(
                binaryName: name, qualifiedName: name, simpleName: simple, packageName: package,
                kind: kind, modifiers: [.publicFlag], superclass: superclass.map { classType($0) },
                origin: .jdkModule("test")
            )
        }
        return [
            object, base,
            type("b.Sub", package: "b", superclass: "a.Base"),
            type("b.Sub.Inner", package: "b"),
            type("b.Sub.InnerBase", package: "b", superclass: "a.Base"),
            type("b.Other", package: "b"),
            type("a.Peer", package: "a"),
            type("p.Bare", package: "p"),
            type("java.lang.String", package: "java.lang", superclass: "java.lang.Object"),
            type("java.util.List", package: "java.util", kind: .interfaceKind),
            type("n.Number", package: "n", superclass: "java.lang.Object")
        ]
    }

    private func memberNames(
        of type: JavaTypeRef, in index: JavaIndex, package: String, enclosing: [String],
        qualifier: JavaMemberQualifier = .expression, checkAccess: Bool = true
    ) async -> Set<String> {
        let context = JavaResolutionContext(packageName: package, imports: [], enclosingTypeQualifiedNames: enclosing)
        let members = await JavaMemberLookup.members(
            of: type, mode: .instance, context: context, index: index, checkAccess: checkAccess, qualifier: qualifier
        )
        return Set(members.map(\.name))
    }

    /// Protected instance members follow the receiver. Same-package, static, `super`, and a subclass
    /// receiver stay visible; `Object.clone`/`finalize` do not appear on `Object`, `String`, an
    /// interface, an unbounded variable, or an array. The array's own public `clone` stays.
    func testProtectedAccessFollowsTheReceiver() async throws {
        let index = try await makeIndex(withStubs: protectedWorld())
        let sub = ["b.Sub"]

        let throughBase = await memberNames(of: classType("a.Base"), in: index, package: "b", enclosing: sub)
        XCTAssertFalse(throughBase.contains("secret"))
        XCTAssertFalse(throughBase.contains("ping"))
        XCTAssertTrue(throughBase.contains("pub"))
        XCTAssertTrue(throughBase.contains("STAT"), "static protected access ignores the receiver")

        let throughSub = await memberNames(of: classType("b.Sub"), in: index, package: "b", enclosing: sub)
        XCTAssertTrue(throughSub.contains("secret"))
        XCTAssertTrue(throughSub.contains("ping"))
        XCTAssertTrue(throughSub.contains("clone"), "this.clone() is legal in a subclass of Object")
        XCTAssertTrue(throughSub.contains("finalize"))

        let throughSuper = await memberNames(of: classType("a.Base"), in: index, package: "b", enclosing: sub, qualifier: .viaSuper)
        XCTAssertTrue(throughSuper.contains("secret"))
        XCTAssertTrue(throughSuper.contains("ping"))

        let throughSimpleName = await memberNames(of: classType("a.Base"), in: index, package: "b", enclosing: sub, qualifier: .simpleName)
        XCTAssertTrue(throughSimpleName.contains("secret"))

        let samePackage = await memberNames(of: classType("a.Base"), in: index, package: "a", enclosing: ["a.Peer"])
        XCTAssertTrue(samePackage.contains("secret"), "same-package access has no receiver restriction")

        let otherBase = await memberNames(of: classType("a.Base"), in: index, package: "b", enclosing: ["b.Other"])
        let otherSub = await memberNames(of: classType("b.Sub"), in: index, package: "b", enclosing: ["b.Other"])
        XCTAssertFalse(otherBase.contains("secret"))
        XCTAssertFalse(otherSub.contains("secret"))
        XCTAssertTrue(otherBase.contains("pub"))

        let inner = ["b.Sub.Inner", "b.Sub"]
        let innerOnBase = await memberNames(of: classType("a.Base"), in: index, package: "b", enclosing: inner)
        let innerOnSub = await memberNames(of: classType("b.Sub"), in: index, package: "b", enclosing: inner)
        let innerOnSelf = await memberNames(of: classType("b.Sub.Inner"), in: index, package: "b", enclosing: inner)
        XCTAssertFalse(innerOnBase.contains("secret"))
        XCTAssertTrue(innerOnSub.contains("secret"), "the outer subclass is a legal receiver")
        XCTAssertFalse(innerOnSelf.contains("secret"))

        let innerBase = ["b.Sub.InnerBase", "b.Sub"]
        let onInnerBase = await memberNames(of: classType("b.Sub.InnerBase"), in: index, package: "b", enclosing: innerBase)
        let innerBaseOnBase = await memberNames(of: classType("a.Base"), in: index, package: "b", enclosing: innerBase)
        XCTAssertTrue(onInnerBase.contains("secret"))
        XCTAssertFalse(innerBaseOnBase.contains("secret"))

        let onObject = await memberNames(of: classType("java.lang.Object"), in: index, package: "b", enclosing: sub)
        let onString = await memberNames(of: classType("java.lang.String"), in: index, package: "b", enclosing: sub)
        XCTAssertFalse(onObject.contains("clone"))
        XCTAssertFalse(onObject.contains("finalize"))
        XCTAssertTrue(onObject.contains("toString"))
        XCTAssertFalse(onString.contains("clone"))
        XCTAssertFalse(onString.contains("finalize"))

        let onList = await memberNames(of: classType("java.util.List"), in: index, package: "b", enclosing: sub)
        XCTAssertTrue(onList.contains("toString"))
        XCTAssertFalse(onList.contains("clone"), "an interface does not have Object.clone")
        XCTAssertFalse(onList.contains("finalize"))
        let listUnchecked = await memberNames(
            of: classType("java.util.List"), in: index, package: "b", enclosing: sub, checkAccess: false
        )
        XCTAssertTrue(listUnchecked.contains("clone"), "inspections still see the protected member when access is not checked")

        let onArray = await memberNames(of: .array(element: classType("java.lang.String")), in: index, package: "b", enclosing: sub)
        XCTAssertTrue(onArray.contains("length"))
        XCTAssertTrue(onArray.contains("toString"))
        XCTAssertFalse(onArray.contains("finalize"))
        let clones = await JavaMemberLookup.members(
            of: .array(element: classType("java.lang.String")), mode: .instance,
            context: JavaResolutionContext(packageName: "b", imports: [], enclosingTypeQualifiedNames: sub), index: index
        ).filter { $0.name == "clone" }
        XCTAssertEqual(clones.count, 1)
        guard case .method(let clone, _) = clones.first else { return XCTFail("expected array clone") }
        XCTAssertEqual(clone.returnType, .array(element: classType("java.lang.String")))
        XCTAssertTrue(clone.modifiers.contains(.publicFlag))

        let unbounded = JavaResolutionContext(
            packageName: "b", imports: [], enclosingTypeQualifiedNames: sub, typeParameterNames: ["T"]
        )
        let onT = Set((await JavaMemberLookup.members(of: .typeVariable(name: "T"), mode: .instance, context: unbounded, index: index)).map(\.name))
        XCTAssertFalse(onT.contains("clone"))
        let extendsSub = JavaResolutionContext(
            packageName: "b", imports: [], enclosingTypeQualifiedNames: sub,
            typeParameterNames: ["T"], typeParameterBounds: ["T": [classType("b.Sub")]]
        )
        let onExtendsSub = Set((await JavaMemberLookup.members(of: .typeVariable(name: "T"), mode: .instance, context: extendsSub, index: index)).map(\.name))
        XCTAssertTrue(onExtendsSub.contains("clone"))
        let extendsObject = JavaResolutionContext(
            packageName: "b", imports: [], enclosingTypeQualifiedNames: sub,
            typeParameterNames: ["T"], typeParameterBounds: ["T": [classType("java.lang.Object")]]
        )
        let onExtendsObject = Set((await JavaMemberLookup.members(of: .typeVariable(name: "T"), mode: .instance, context: extendsObject, index: index)).map(\.name))
        XCTAssertFalse(onExtendsObject.contains("clone"))

        let bare = await memberNames(of: classType("p.Bare"), in: index, package: "p", enclosing: ["p.Bare"])
        XCTAssertTrue(bare.contains("clone"), "a source class with no written superclass still subclasses Object")
        let bareOnObject = await memberNames(of: classType("java.lang.Object"), in: index, package: "p", enclosing: ["p.Bare"])
        XCTAssertFalse(bareOnObject.contains("clone"))

        let fromSub = await JavaMemberLookup.constructors(
            of: classType("a.Base"),
            context: JavaResolutionContext(packageName: "b", imports: [], enclosingTypeQualifiedNames: sub),
            index: index
        )
        XCTAssertEqual(fromSub.count, 1)
        let fromOther = await JavaMemberLookup.constructors(
            of: classType("a.Base"),
            context: JavaResolutionContext(packageName: "b", imports: [], enclosingTypeQualifiedNames: ["b.Other"]),
            index: index
        )
        XCTAssertTrue(fromOther.isEmpty)
    }

    /// An interface is processed before a superclass that has not yet queued `Object` (the walk is a
    /// FIFO). That public-only visit must not consume `Object`, or `clone` and `finalize` disappear
    /// on a class receiver that can legally see them. They stay hidden on an interface, on `Object`,
    /// on `String`, on an unrelated class, on an array, and on a variable bounded by `Object`.
    func testInterfaceVisitDoesNotSuppressProtectedObjectMembers() async throws {
        func type(
            _ name: String, package: String, kind: JavaTypeKind = .classKind,
            superclass: String? = nil, interfaces: [String] = [], methods: [JavaMethodStub] = []
        ) -> JavaClassStub {
            let simple = String(name.split(separator: ".").last!)
            return JavaClassStub(
                binaryName: name, qualifiedName: name, simpleName: simple, packageName: package,
                kind: kind, modifiers: [.publicFlag],
                superclass: superclass.map { classType($0) },
                interfaces: interfaces.map { classType($0) },
                methods: methods, origin: .jdkModule("test")
            )
        }
        let object = JavaClassStub(
            binaryName: "java.lang.Object", qualifiedName: "java.lang.Object", simpleName: "Object", packageName: "java.lang",
            kind: .classKind, modifiers: [.publicFlag],
            methods: [
                JavaMethodStub(name: "toString", parameters: [], returnType: classType("java.lang.String"), modifiers: [.publicFlag]),
                JavaMethodStub(name: "equals", parameters: [JavaParameterStub(name: "other", type: classType("java.lang.Object"))], returnType: .primitive(.boolean), modifiers: [.publicFlag]),
                JavaMethodStub(name: "clone", parameters: [], returnType: classType("java.lang.Object"), modifiers: [.protectedFlag]),
                JavaMethodStub(name: "finalize", parameters: [], returnType: .void, modifiers: [.protectedFlag])
            ],
            origin: .jdkModule("test")
        )
        let fromBase = JavaMethodStub(name: "fromBase", parameters: [], returnType: .void, modifiers: [.publicFlag])
        let index = try await makeIndex(withStubs: [
            object,
            type("p.Marker", package: "p", kind: .interfaceKind),
            type("java.io.Serializable", package: "java.io", kind: .interfaceKind),
            type("p.Base", package: "p", methods: [fromBase]),
            type("p.Mid", package: "p", superclass: "p.Base", interfaces: ["p.Marker"]),
            type("p.Holder", package: "p", superclass: "p.Mid", interfaces: ["java.io.Serializable"]),
            type("p.Direct", package: "p", interfaces: ["p.Marker"]),
            type("p.Sibling", package: "p"),
            type("java.lang.String", package: "java.lang", superclass: "java.lang.Object")
        ])
        let enclosing = ["p.Holder"]
        let holder = await memberNames(of: classType("p.Holder"), in: index, package: "p", enclosing: enclosing)
        XCTAssertTrue(holder.contains("clone"))
        XCTAssertTrue(holder.contains("finalize"))
        XCTAssertTrue(holder.contains("toString"))
        XCTAssertTrue(holder.contains("fromBase"))

        let listed = await JavaMemberLookup.members(
            of: classType("p.Holder"), mode: .instance,
            context: JavaResolutionContext(packageName: "p", imports: [], enclosingTypeQualifiedNames: enclosing),
            index: index
        )
        XCTAssertEqual(listed.filter { $0.name == "clone" }.count, 1, "the second Object visit must not duplicate clone")
        XCTAssertEqual(listed.filter { $0.name == "toString" }.count, 1, "public Object methods are recorded once")
        XCTAssertEqual(listed.filter { $0.name == "finalize" }.count, 1)
        let again = await JavaMemberLookup.members(
            of: classType("p.Holder"), mode: .instance,
            context: JavaResolutionContext(packageName: "p", imports: [], enclosingTypeQualifiedNames: enclosing),
            index: index
        )
        XCTAssertEqual(again.count, listed.count, "a repeated lookup is the cached set, not another Object walk")

        let direct = await memberNames(of: classType("p.Direct"), in: index, package: "p", enclosing: ["p.Direct"])
        XCTAssertTrue(direct.contains("clone"))
        let directMembers = await JavaMemberLookup.members(
            of: classType("p.Direct"), mode: .instance,
            context: JavaResolutionContext(packageName: "p", imports: [], enclosingTypeQualifiedNames: ["p.Direct"]),
            index: index
        )
        XCTAssertEqual(directMembers.filter { $0.name == "clone" }.count, 1)

        let onMarker = await memberNames(of: classType("p.Marker"), in: index, package: "p", enclosing: enclosing)
        XCTAssertTrue(onMarker.contains("toString"))
        XCTAssertFalse(onMarker.contains("clone"))
        XCTAssertFalse(onMarker.contains("finalize"))
        let markerUnchecked = await memberNames(
            of: classType("p.Marker"), in: index, package: "p", enclosing: enclosing, checkAccess: false
        )
        XCTAssertTrue(markerUnchecked.contains("clone"), "inspections still see the protected member")

        let onObject = await memberNames(of: classType("java.lang.Object"), in: index, package: "p", enclosing: enclosing)
        let onString = await memberNames(of: classType("java.lang.String"), in: index, package: "p", enclosing: enclosing)
        let onSibling = await memberNames(of: classType("p.Sibling"), in: index, package: "p", enclosing: enclosing)
        XCTAssertFalse(onObject.contains("clone"))
        XCTAssertFalse(onString.contains("clone"))
        XCTAssertFalse(onSibling.contains("clone"))
        XCTAssertFalse(onSibling.contains("finalize"))

        let onArray = await memberNames(of: .array(element: classType("java.lang.String")), in: index, package: "p", enclosing: enclosing)
        XCTAssertFalse(onArray.contains("finalize"))
        let arrayClones = await JavaMemberLookup.members(
            of: .array(element: classType("java.lang.String")), mode: .instance,
            context: JavaResolutionContext(packageName: "p", imports: [], enclosingTypeQualifiedNames: enclosing),
            index: index
        ).filter { $0.name == "clone" }
        XCTAssertEqual(arrayClones.count, 1)
        guard case .method(let arrayClone, _) = arrayClones.first else { return XCTFail("expected the array clone") }
        XCTAssertTrue(arrayClone.modifiers.contains(.publicFlag))

        let extendsObject = JavaResolutionContext(
            packageName: "p", imports: [], enclosingTypeQualifiedNames: enclosing,
            typeParameterNames: ["T"], typeParameterBounds: ["T": [classType("java.lang.Object")]]
        )
        let onBound = Set((await JavaMemberLookup.members(
            of: .typeVariable(name: "T"), mode: .instance, context: extendsObject, index: index
        )).map(\.name))
        XCTAssertFalse(onBound.contains("clone"))
        XCTAssertFalse(onBound.contains("finalize"))
    }
}

extension JavaResolvedMember: Equatable {
    public static func == (lhs: JavaResolvedMember, rhs: JavaResolvedMember) -> Bool {
        lhs.name == rhs.name && lhs.declaringClass == rhs.declaringClass
    }
}
