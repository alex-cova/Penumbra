import XCTest
@testable import JavaIntelligence

/// `JavaTypeSystem`: substitution, erasure, multi-catch lub and the `var` seam.
final class JavaTypeSystemTests: XCTestCase {
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

    private func stub(
        _ qualifiedName: String, superclass: String? = nil, interfaces: [String] = [],
        typeParameters: [String] = [], kind: JavaTypeKind = .classKind, genericSuper: Bool = false
    ) -> JavaClassStub {
        let simple = String(qualifiedName.split(separator: ".").last!)
        let pkg = qualifiedName.contains(".") ? qualifiedName.components(separatedBy: ".").dropLast().joined(separator: ".") : ""
        func ref(_ name: String) -> JavaTypeRef {
            .classType(qualifiedName: name, arguments: [], outer: nil)
        }
        return JavaClassStub(
            binaryName: qualifiedName, qualifiedName: qualifiedName, simpleName: simple, packageName: pkg,
            kind: kind, modifiers: [.publicFlag],
            typeParameters: typeParameters.map { JavaTypeParameter(name: $0, bounds: []) },
            superclass: superclass.map { name in
                genericSuper ? .classType(qualifiedName: name, arguments: typeParameters.map { .type(.typeVariable(name: $0)) }, outer: nil) : ref(name)
            },
            interfaces: interfaces.map { name in
                genericSuper ? .classType(qualifiedName: name, arguments: typeParameters.map { .type(.typeVariable(name: $0)) }, outer: nil) : ref(name)
            },
            origin: .jdkModule("test"))
    }

    private func classType(_ name: String, _ arguments: [JavaTypeArgument] = []) -> JavaTypeRef {
        .classType(qualifiedName: name, arguments: arguments, outer: nil)
    }

    // MARK: - substitution

    func testSubstituteReplacesTypeVariables() {
        let type = classType("java.util.List", [.type(.typeVariable(name: "T"))])
        let result = JavaTypeSystem.substitute(type, using: ["T": .primitive(.int)])
        XCTAssertEqual(result, classType("java.util.List", [.type(.primitive(.int))]))
    }

    func testSubstituteRecursesAndLeavesUnknownVariables() {
        let type = JavaTypeRef.array(element: .typeVariable(name: "U"))
        XCTAssertEqual(
            JavaTypeSystem.substitute(type, using: ["T": .primitive(.int)]),
            .array(element: .typeVariable(name: "U")))
        XCTAssertEqual(
            JavaTypeSystem.substitute(type, using: ["U": classType("java.lang.String")]),
            .array(element: classType("java.lang.String")))
    }

    func testSubstituteEmptyMapIsIdentity() {
        let type = classType("java.util.Map", [.type(.typeVariable(name: "K"))])
        XCTAssertEqual(JavaTypeSystem.substitute(type, using: [:]), type)
    }

    // MARK: - erasure

    func testErasureDropsArguments() {
        XCTAssertEqual(
            JavaTypeSystem.erasure(of: classType("java.util.List", [.type(.primitive(.int))])),
            classType("java.util.List"))
    }

    func testErasureOfVariableAndWildcardIsObject() {
        let object = classType("java.lang.Object")
        XCTAssertEqual(JavaTypeSystem.erasure(of: .typeVariable(name: "T")), object)
        XCTAssertEqual(JavaTypeSystem.erasure(of: .wildcard(bound: nil)), object)
        XCTAssertEqual(
            JavaTypeSystem.erasure(of: .wildcard(bound: .extends(classType("java.lang.Number")))),
            classType("java.lang.Number"))
    }

    func testErasureRecursesIntoArraysAndKeepsUnresolved() {
        XCTAssertEqual(
            JavaTypeSystem.erasure(of: .array(element: classType("java.util.List", [.type(.primitive(.int))]))),
            .array(element: classType("java.util.List")))
        XCTAssertEqual(
            JavaTypeSystem.erasure(of: .unresolved(simpleName: "Foo", arguments: [])),
            .unresolved(simpleName: "Foo", arguments: []))
        XCTAssertEqual(JavaTypeSystem.erasure(of: .primitive(.int)), .primitive(.int))
    }

    // MARK: - lub for multi-catch

    func testLubOfSameErasureKeepsArguments() async throws {
        let index = try await makeIndex(withStubs: [])
        let first = classType("java.io.IOException", [.type(.primitive(.int))])
        let second = classType("java.io.IOException", [.type(.primitive(.boolean))])
        let result = await JavaTypeSystem.lub(of: [first, second], index: index)
        XCTAssertEqual(result, first)
    }

    func testLubOfSubclassPairIsSuperclass() async throws {
        let index = try await makeIndex(withStubs: [
            stub("java.lang.Throwable"),
            stub("java.lang.Exception", superclass: "java.lang.Throwable"),
            stub("java.io.IOException", superclass: "java.lang.Exception"),
            stub("java.io.FileNotFoundException", superclass: "java.io.IOException"),
        ])
        let lub = await JavaTypeSystem.lub(
            of: [classType("java.io.FileNotFoundException"), classType("java.io.IOException")],
            index: index)
        XCTAssertEqual(lub, classType("java.io.IOException"))
    }

    func testLubOfSiblingsIsCommonSupertype() async throws {
        let index = try await makeIndex(withStubs: [
            stub("java.lang.Throwable"),
            stub("java.lang.Exception", superclass: "java.lang.Throwable"),
            stub("java.io.IOException", superclass: "java.lang.Exception"),
            stub("java.lang.RuntimeException", superclass: "java.lang.Exception"),
        ])
        let lub = await JavaTypeSystem.lub(
            of: [classType("java.io.IOException"), classType("java.lang.RuntimeException")],
            index: index)
        XCTAssertEqual(lub, classType("java.lang.Exception"))
    }

    func testLubOfUnresolvableIsNil() async throws {
        let index = try await makeIndex(withStubs: [])
        let lub = await JavaTypeSystem.lub(
            of: [.unresolved(simpleName: "Foo", arguments: []), classType("java.lang.Exception")],
            index: index)
        XCTAssertNil(lub)
    }

    func testEffectiveCatchTypeFallsBackToFirst() async throws {
        let index = try await makeIndex(withStubs: [])
        let first = JavaTypeRef.unresolved(simpleName: "Foo", arguments: [])
        let effective = await JavaTypeSystem.effectiveCatchType(
            alternatives: [first, classType("java.lang.Exception")], index: index)
        XCTAssertEqual(effective, first)
    }

    func testEffectiveCatchTypeOfEmptyIsThrowable() async throws {
        let index = try await makeIndex(withStubs: [])
        let effective = await JavaTypeSystem.effectiveCatchType(alternatives: [], index: index)
        XCTAssertEqual(effective, .unresolved(simpleName: "Throwable", arguments: []))
    }

    // MARK: - var seam

    func testInferredVarTypePassesConcreteTypesThrough() {
        XCTAssertEqual(
            JavaTypeSystem.inferredVarType(initializerType: classType("java.lang.String")),
            classType("java.lang.String"))
        XCTAssertNil(JavaTypeSystem.inferredVarType(initializerType: nil))
        XCTAssertNil(JavaTypeSystem.inferredVarType(
            initializerType: .unresolved(simpleName: "var", arguments: [])))
    }

    // MARK: - lub with arguments, conditional typing (F01)

    private func hierarchy() async throws -> JavaIndex {
        try await makeIndex(withStubs: [
            stub("java.lang.Object"),
            stub("java.lang.Number", superclass: "java.lang.Object", interfaces: ["java.io.Serializable"]),
            stub("java.lang.Integer", superclass: "java.lang.Number", interfaces: ["java.lang.Comparable"]),
            stub("java.lang.Double", superclass: "java.lang.Number", interfaces: ["java.lang.Comparable"]),
            stub("java.lang.String", superclass: "java.lang.Object", interfaces: ["java.io.Serializable", "java.lang.Comparable"]),
            stub("java.io.Serializable", kind: .interfaceKind), stub("java.lang.Comparable", typeParameters: ["T"], kind: .interfaceKind),
            stub("java.util.AbstractList", superclass: "java.lang.Object", interfaces: ["java.util.List"], typeParameters: ["E"]),
            stub("java.util.ArrayList", superclass: "java.util.AbstractList", typeParameters: ["E"], genericSuper: true),
            stub("java.util.LinkedList", superclass: "java.util.AbstractList", typeParameters: ["E"], genericSuper: true),
            stub("java.util.List", typeParameters: ["E"], kind: .interfaceKind)
        ])
    }

    /// No single most specific common type: the minimal class stands for the intersection.
    func testLubOfTwoBoxedNumbersIsNumber() async throws {
        let index = try await hierarchy()
        let lub = await JavaTypeSystem.lub(of: [classType("java.lang.Integer"), classType("java.lang.Double")], index: index)
        XCTAssertEqual(lub?.erasedQualifiedName, "java.lang.Number")
    }

    func testLubWithNoClassInCommonPicksAMinimalInterface() async throws {
        let index = try await hierarchy()
        let lub = await JavaTypeSystem.lub(of: [classType("java.lang.Integer"), classType("java.lang.String")], index: index)
        XCTAssertNotNil(lub)
        XCTAssertNotEqual(lub?.erasedQualifiedName, "java.lang.Object")
    }

    func testLubKeepsTheArgumentsTheArmsAgreeOn() async throws {
        let index = try await hierarchy()
        let string = JavaTypeArgument.type(classType("java.lang.String"))
        let result = await JavaTypeSystem.lubKeepingArguments(
            of: [classType("java.util.ArrayList", [string]), classType("java.util.LinkedList", [string])], index: index)
        XCTAssertEqual(result, classType("java.util.AbstractList", [string]))
    }

    func testLubBlursTheArgumentsTheArmsDisagreeOn() async throws {
        let index = try await hierarchy()
        let result = await JavaTypeSystem.lubKeepingArguments(
            of: [
                classType("java.util.ArrayList", [.type(classType("java.lang.String"))]),
                classType("java.util.LinkedList", [.type(classType("java.lang.Integer"))])
            ], index: index)
        XCTAssertEqual(result, classType("java.util.AbstractList", [.wildcard(nil)]))
    }

    func testAnEnclosingClassVariableSeenFromAMemberClassIsSubstituted() {
        // `T` inside `Outer<T>.Inner` is a bare name resolution could not place.
        XCTAssertEqual(
            JavaTypeSystem.substitute(.unresolved(simpleName: "T", arguments: []), using: ["T": classType("java.lang.String")]),
            classType("java.lang.String"))
        XCTAssertEqual(
            JavaTypeSystem.substitute(.unresolved(simpleName: "Other", arguments: []), using: ["T": classType("java.lang.String")]),
            .unresolved(simpleName: "Other", arguments: []))
    }

    func testConditionalTypingFollowsTheNumericAndBooleanRules() async throws {
        let index = try await hierarchy()
        let int = JavaTypeRef.primitive(.int)
        let double = JavaTypeRef.primitive(.double)
        let null = JavaTypeRef.unresolved(simpleName: "null", arguments: [])
        func conditional(_ arms: [JavaTypeRef]) async -> JavaTypeRef? { await JavaExpressionTyper.conditionalType(of: arms, index: index) }
        let promoted = await conditional([int, double])
        XCTAssertEqual(promoted, double)
        let unboxed = await conditional([classType("java.lang.Integer"), double])
        XCTAssertEqual(unboxed, double)
        let same = await conditional([int, int])
        XCTAssertEqual(same, int)
        let small = await conditional([.primitive(.byte), .primitive(.short)])
        XCTAssertEqual(small, .primitive(.short))
        let flags = await conditional([.primitive(.boolean), classType("java.lang.Boolean")])
        XCTAssertEqual(flags, .primitive(.boolean))
        let boxedNull = await conditional([null, int])
        XCTAssertEqual(boxedNull, classType("java.lang.Integer"))
        let onlyNull = await conditional([null])
        XCTAssertEqual(onlyNull, null)
        let mixed = await conditional([int, classType("java.lang.String")])
        XCTAssertNotEqual(mixed, int)
    }
}
