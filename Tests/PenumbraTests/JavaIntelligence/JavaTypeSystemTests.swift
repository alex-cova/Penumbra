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

    // MARK: - wildcard containment during overload applicability

    /// `Map<String, Long>` is a `Map<? extends K#, ? extends V#>`: the bounds are inference
    /// variables. `List<String>` is not a `List<? extends Integer>`, and a class type variable
    /// or an unresolved name is not an inference variable.
    func testInferenceVariableWildcardBoundsStayApplicable() async {
        let index = JavaIndex()
        let context = JavaResolutionContext(packageName: "", imports: [])
        let assignability = JavaAssignability(index: index, context: context)
        let map = classType("java.util.Map", [
            .type(classType("java.lang.String")),
            .type(classType("java.lang.Long")),
        ])
        let extendsVariables = classType("java.util.Map", [
            .wildcard(.extends(.typeVariable(name: "K#"))),
            .wildcard(.extends(.typeVariable(name: "V#"))),
        ])
        let comparator = classType("java.util.Comparator", [.type(classType("java.lang.String"))])
        let superVariable = classType("java.util.Comparator", [
            .wildcard(.superBound(.typeVariable(name: "T#"))),
        ])
        let listString = classType("java.util.List", [.type(classType("java.lang.String"))])
        let mapFits = await assignability.isAssignable(map, to: extendsVariables)
        let comparatorFits = await assignability.isAssignable(comparator, to: superVariable)
        let integerBound = await assignability.isAssignable(
            listString,
            to: classType("java.util.List", [.wildcard(.extends(classType("java.lang.Integer")))]))
        let classVariable = await assignability.isAssignable(
            listString,
            to: classType("java.util.List", [.wildcard(.extends(.typeVariable(name: "T")))]))
        let unresolvedName = await assignability.isAssignable(
            listString,
            to: classType("java.util.List", [.wildcard(.extends(.unresolved(simpleName: "Integer", arguments: [])))]))
        XCTAssertTrue(mapFits)
        XCTAssertTrue(comparatorFits)
        XCTAssertFalse(integerBound)
        XCTAssertFalse(classVariable)
        XCTAssertFalse(unresolvedName)
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

    /// `JsonProcessingException | JsonPatchException` when the index is missing one or both
    /// alternatives. A closure of a missing class is `{itself, Object}`, so the meet is `Object`
    /// without this guard. That is not a lub, and the catch parameter is not `Object`: it is
    /// `Throwable`, which every catch alternative is below (JLS 14.20), and not the first written
    /// alternative, whose own members need not belong to the lub (and which has none when it is the
    /// missing one). Two indexed classes that share nothing but `Object` still lub to `Object`. Both
    /// indexed and meeting at `Exception` still lub to `Exception` (the complete-classpath case).
    func testLubOfAMissingClassIsNotObject() async throws {
        let missingJackson = classType("com.fasterxml.jackson.core.JsonProcessingException")
        let missingPatch = classType("com.github.fge.jsonpatch.JsonPatchException")
        let present = classType("com.example.Present")
        let throwable = classType("java.lang.Throwable")
        let incomplete = try await makeIndex(withStubs: [
            stub("java.lang.Throwable"),
            stub("java.lang.Exception", superclass: "java.lang.Throwable"),
            stub("com.example.Present", superclass: "java.lang.Exception"),
        ])
        let oneMissing = await JavaTypeSystem.lub(of: [missingJackson, present], index: incomplete)
        XCTAssertNil(oneMissing)
        let catchOne = await JavaTypeSystem.effectiveCatchType(
            alternatives: [missingJackson, present], index: incomplete)
        XCTAssertEqual(catchOne, throwable)
        XCTAssertNotEqual(catchOne, classType("java.lang.Object"))
        XCTAssertNotEqual(catchOne, missingJackson)

        let bothMissing = await JavaTypeSystem.lub(of: [missingJackson, missingPatch], index: incomplete)
        XCTAssertNil(bothMissing)
        let catchBoth = await JavaTypeSystem.effectiveCatchType(
            alternatives: [missingJackson, missingPatch], index: incomplete)
        XCTAssertEqual(catchBoth, throwable)
        XCTAssertNotEqual(catchBoth, classType("java.lang.Object"))

        let onlyObject = try await makeIndex(withStubs: [
            stub("java.lang.Object"),
            stub("com.example.Left", superclass: "java.lang.Object"),
            stub("com.example.Right", superclass: "java.lang.Object"),
        ])
        let unrelated = await JavaTypeSystem.lub(
            of: [classType("com.example.Left"), classType("com.example.Right")], index: onlyObject)
        XCTAssertEqual(unrelated, classType("java.lang.Object"))

        let complete = try await makeIndex(withStubs: [
            stub("java.lang.Throwable"),
            stub("java.lang.Exception", superclass: "java.lang.Throwable"),
            stub("com.fasterxml.jackson.core.JacksonException", superclass: "java.lang.Exception"),
            stub("com.fasterxml.jackson.core.JsonProcessingException", superclass: "com.fasterxml.jackson.core.JacksonException"),
            stub("com.github.fge.jsonpatch.JsonPatchException", superclass: "java.lang.Exception"),
        ])
        let lub = await JavaTypeSystem.lub(of: [missingJackson, missingPatch], index: complete)
        XCTAssertEqual(lub, classType("java.lang.Exception"))
        let catchComplete = await JavaTypeSystem.effectiveCatchType(alternatives: [missingJackson, missingPatch], index: complete)
        XCTAssertEqual(catchComplete, classType("java.lang.Exception"))
    }

    /// The classpath shapes javac was run on (`Tools/JavaReceiverOracle`, Jackson 2.19.4 core and
    /// json-patch 1.13): both present, javac's parameter is `Exception`; only one present, javac prints
    /// the lub of the alternatives it could resolve (`JsonPatchException`, or `JsonProcessingException`)
    /// and reports `package … does not exist`; neither, no type. The engine answers `Exception` with the
    /// complete classpath and `Throwable` whenever the index cannot prove more, in either written order.
    /// The first written alternative was the old fallback: in `SQLException | NotIndexed` it offered
    /// `getSQLState()`, which the real lub (here `Exception`) does not have.
    func testIncompleteMultiCatchIsThrowableInEitherOrder() async throws {
        let sql = classType("java.sql.SQLException")
        let missing = classType("com.example.NotIndexed")
        let throwable = classType("java.lang.Throwable")
        let index = try await makeIndex(withStubs: [
            stub("java.lang.Object"),
            stub("java.lang.Throwable", superclass: "java.lang.Object"),
            stub("java.lang.Exception", superclass: "java.lang.Throwable"),
            stub("java.lang.RuntimeException", superclass: "java.lang.Exception"),
            stub("java.io.IOException", superclass: "java.lang.Exception"),
            stub("java.sql.SQLException", superclass: "java.lang.Exception"),
            stub("java.lang.String", superclass: "java.lang.Object", interfaces: ["java.io.Serializable"]),
            stub("java.io.Serializable", kind: .interfaceKind),
            // A library exception whose superclass's jar is missing, and which implements an interface
            // `Throwable` also has: the meet climbs to `Serializable`, above every catch type.
            stub("com.example.LibraryException", superclass: "com.example.MissingBase", interfaces: ["java.io.Serializable"]),
        ])
        let first = await JavaTypeSystem.effectiveCatchType(alternatives: [sql, missing], index: index)
        let second = await JavaTypeSystem.effectiveCatchType(alternatives: [missing, sql], index: index)
        XCTAssertEqual(first, throwable)
        XCTAssertEqual(second, throwable)

        let cut = await JavaTypeSystem.effectiveCatchType(
            alternatives: [classType("java.io.IOException"), classType("com.example.LibraryException")], index: index)
        XCTAssertEqual(cut, throwable)

        // Invalid code (`String` is not a `Throwable`): javac reports it and recovers; the engine stays at `Throwable`.
        let invalid = await JavaTypeSystem.effectiveCatchType(
            alternatives: [classType("java.io.IOException"), classType("java.lang.String")], index: index)
        XCTAssertEqual(invalid, throwable)

        // Fully indexed alternatives keep their lub.
        let indexed = await JavaTypeSystem.effectiveCatchType(
            alternatives: [classType("java.io.IOException"), classType("java.lang.RuntimeException")], index: index)
        XCTAssertEqual(indexed, classType("java.lang.Exception"))
        let subclassPair = await JavaTypeSystem.effectiveCatchType(alternatives: [sql, classType("java.lang.Exception")], index: index)
        XCTAssertEqual(subclassPair, classType("java.lang.Exception"))
    }

    /// No `Throwable` in the index (no JDK yet): nothing can be proved, so the lub, else the first
    /// written alternative, stands as before.
    func testMultiCatchWithoutAnIndexedThrowableKeepsTheOldFallback() async throws {
        let index = try await makeIndex(withStubs: [
            stub("java.lang.Exception"),
            stub("java.io.IOException", superclass: "java.lang.Exception"),
            stub("java.lang.RuntimeException", superclass: "java.lang.Exception"),
        ])
        let missing = classType("com.example.NotIndexed")
        let fallback = await JavaTypeSystem.effectiveCatchType(alternatives: [missing, classType("java.io.IOException")], index: index)
        XCTAssertEqual(fallback, missing)
        let lub = await JavaTypeSystem.effectiveCatchType(
            alternatives: [classType("java.io.IOException"), classType("java.lang.RuntimeException")], index: index)
        XCTAssertEqual(lub, classType("java.lang.Exception"))
    }

    func testWildcardApplicabilityRejectsClosedBoundsAndKeepsRawTypes() async throws {
        let index = JavaIndex()
        let assignability = JavaAssignability(index: index, context: JavaResolutionContext(packageName: "", imports: []))
        let listString = classType("java.util.List", [.type(classType("java.lang.String"))])
        let unbounded = await assignability.isAssignable(
            listString, to: classType("java.util.List", [.wildcard(nil)]))
        let lowerRejects = await assignability.isAssignable(
            classType("java.util.Comparator", [.type(classType("java.lang.Integer"))]),
            to: classType("java.util.Comparator", [.wildcard(.superBound(classType("java.lang.String")))]))
        let lowerAcceptsObject = await assignability.isAssignable(
            classType("java.util.Comparator", [.type(classType("java.lang.Object"))]),
            to: classType("java.util.Comparator", [.wildcard(.superBound(classType("java.lang.String")))]))
        let upperRejects = await assignability.isAssignable(
            listString,
            to: classType("java.util.List", [.wildcard(.extends(classType("java.lang.Number")))]))
        let rawToParameterized = await assignability.isAssignable(classType("java.util.List"), to: listString)
        let parameterizedToRaw = await assignability.isAssignable(listString, to: classType("java.util.List"))
        XCTAssertTrue(unbounded)
        XCTAssertFalse(lowerRejects)
        XCTAssertTrue(lowerAcceptsObject)
        XCTAssertFalse(upperRejects)
        XCTAssertTrue(rawToParameterized)
        XCTAssertTrue(parameterizedToRaw)
    }

    /// `Class<? extends String>` is the engine's type of `getClass()` on a `String` (JLS 4.3.2, before
    /// capture). It converts to `Class<? extends CharSequence>` and `Class<?>`, and not to `Class<String>`
    /// or `Class<? super String>`. An inference variable on the extends side stays applicable.
    func testGetClassWildcardIsNotContainedBySuperOrExactClass() async throws {
        let index = try await makeIndex(withStubs: [
            stub("java.lang.CharSequence", kind: .interfaceKind),
            stub("java.lang.String", interfaces: ["java.lang.CharSequence"]),
        ])
        let assignability = JavaAssignability(index: index, context: JavaResolutionContext(packageName: "", imports: []))
        func classOf(_ argument: JavaTypeArgument) -> JavaTypeRef {
            classType("java.lang.Class", [argument])
        }
        let getClass = classOf(.wildcard(.extends(classType("java.lang.String"))))
        let toExact = await assignability.isAssignable(getClass, to: classOf(.type(classType("java.lang.String"))))
        let toSuper = await assignability.isAssignable(
            getClass, to: classOf(.wildcard(.superBound(classType("java.lang.String")))))
        let toUpper = await assignability.isAssignable(
            getClass, to: classOf(.wildcard(.extends(classType("java.lang.CharSequence")))))
        let toObject = await assignability.isAssignable(
            getClass, to: classOf(.wildcard(.extends(classType("java.lang.Object")))))
        let toUnbounded = await assignability.isAssignable(getClass, to: classOf(.wildcard(nil)))
        let inference = await assignability.isAssignable(
            classOf(.wildcard(.extends(.typeVariable(name: "T#")))),
            to: classOf(.wildcard(.superBound(classType("java.lang.String"))))
        )
        XCTAssertFalse(toExact)
        XCTAssertFalse(toSuper)
        XCTAssertTrue(toUpper)
        XCTAssertTrue(toObject)
        XCTAssertTrue(toUnbounded)
        XCTAssertTrue(inference)
    }

    /// The inapplicable overload is declared first. Selection follows applicability
    /// (`Collection<?>` accepts `List<String>`; `List<? extends Integer>` does not), then
    /// specificity, in either declaration order. An inherited `<T> pick(Collection<? extends T>)`
    /// stays applicable because `T` is renamed to an inference variable.
    func testApplicableOverloadIsNotChosenByDeclarationOrder() async throws {
        let collection = stub("java.util.Collection", typeParameters: ["E"], kind: .interfaceKind)
        let list = stub("java.util.List", interfaces: ["java.util.Collection"], typeParameters: ["E"], kind: .interfaceKind)
        let base = JavaClassStub(
            binaryName: "p.Base", qualifiedName: "p.Base", simpleName: "Base", packageName: "p",
            kind: .classKind, modifiers: [.publicFlag],
            methods: [method(
                "pick",
                parameters: [classType("java.util.Collection", [.wildcard(.extends(.typeVariable(name: "T")))])],
                result: classType("java.lang.String"),
                typeParameters: ["T"]
            )],
            origin: .jdkModule("test")
        )
        let sub = JavaClassStub(
            binaryName: "p.Sub", qualifiedName: "p.Sub", simpleName: "Sub", packageName: "p",
            kind: .classKind, modifiers: [.publicFlag],
            superclass: classType("p.Base"),
            methods: [method(
                "pick",
                parameters: [classType("java.util.List", [.wildcard(.extends(classType("java.lang.Integer")))])],
                result: classType("java.lang.Integer")
            )],
            origin: .jdkModule("test")
        )
        let index = try await makeIndex(withStubs: [collection, list, base, sub])
        let context = JavaResolutionContext(packageName: "p", imports: [])
        let members = await JavaMemberLookup.members(
            of: classType("p.Sub"), mode: .instance, context: context, index: index)
        let inherited = members.compactMap { member -> JavaMethodStub? in
            guard case .method(let method, _) = member, method.name == "pick",
                  method.typeParameters.contains(where: { $0.name == "T" }) else { return nil }
            return method
        }
        XCTAssertEqual(inherited.count, 1)
        let inapplicable = method(
            "pick",
            parameters: [classType("java.util.List", [.wildcard(.extends(classType("java.lang.Integer")))])],
            result: classType("java.lang.Integer")
        )
        let applicable = try XCTUnwrap(inherited.first)
        let argument = classType("java.util.List", [.type(classType("java.lang.String"))])
        let badFirst = await JavaExpressionTyper.resolveOverloads(
            [inapplicable, applicable], argumentTypes: [argument], context: context, index: index)
        let goodFirst = await JavaExpressionTyper.resolveOverloads(
            [applicable, inapplicable], argumentTypes: [argument], context: context, index: index)
        XCTAssertEqual(badFirst.map(\.returnType), [classType("java.lang.String")])
        XCTAssertEqual(goodFirst.map(\.returnType), [classType("java.lang.String")])

        let objectString = method(
            "m", parameters: [classType("java.lang.Object"), classType("java.lang.String")],
            result: classType("java.lang.Integer"))
        let stringObject = method(
            "m", parameters: [classType("java.lang.String"), classType("java.lang.Object")],
            result: classType("java.lang.Long"))
        let ambiguous = await JavaExpressionTyper.resolveOverloads(
            [objectString, stringObject],
            argumentTypes: [classType("java.lang.String"), classType("java.lang.String")],
            context: context, index: index)
        XCTAssertEqual(
            Set(ambiguous.compactMap(\.returnType.erasedQualifiedName)),
            ["java.lang.Integer", "java.lang.Long"])
    }

    private func method(
        _ name: String, parameters: [JavaTypeRef], result: JavaTypeRef, typeParameters: [String] = []
    ) -> JavaMethodStub {
        JavaMethodStub(
            name: name,
            typeParameters: typeParameters.map { JavaTypeParameter(name: $0, bounds: []) },
            parameters: parameters.enumerated().map { JavaParameterStub(name: "p\($0.offset)", type: $0.element) },
            returnType: result,
            modifiers: [.publicFlag]
        )
    }

    // MARK: - var seam

    func testInferredVarTypePassesConcreteTypesThrough() {
        XCTAssertEqual(
            JavaTypeSystem.inferredVarType(initializerType: classType("java.lang.String")),
            classType("java.lang.String"))
        XCTAssertNil(JavaTypeSystem.inferredVarType(initializerType: nil))
        XCTAssertNil(JavaTypeSystem.inferredVarType(
            initializerType: .unresolved(simpleName: "var", arguments: [])))
        XCTAssertNil(JavaTypeSystem.inferredVarType(
            initializerType: .unresolved(simpleName: "null", arguments: [])))
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
