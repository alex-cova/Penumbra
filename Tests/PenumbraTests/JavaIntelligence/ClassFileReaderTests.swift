import XCTest
@testable import JavaIntelligence

final class ClassFileReaderTests: XCTestCase {
    private func readFixture(_ name: String, options: ClassFileReadOptions = ClassFileReadOptions()) throws -> JavaClassStub {
        let data = JavaFixtures.classFile(name)
        return try ClassFileReader.read(data, origin: .jdkModule("test"), options: options)
    }

    func testBasicClassIdentity() throws {
        let stub = try readFixture("Fixture")
        XCTAssertEqual(stub.simpleName, "Fixture")
        XCTAssertEqual(stub.packageName, "com.penumbra.fixture")
        XCTAssertEqual(stub.qualifiedName, "com.penumbra.fixture.Fixture")
        XCTAssertEqual(stub.kind, .classKind)
        XCTAssertTrue(stub.modifiers.contains(.publicFlag))
        XCTAssertNil(stub.outerQualifiedName)
    }

    func testGenericTypeParameterWithBound() throws {
        let stub = try readFixture("Fixture")
        XCTAssertEqual(stub.typeParameters.count, 1)
        let param = try XCTUnwrap(stub.typeParameters.first)
        XCTAssertEqual(param.name, "T")
        XCTAssertEqual(param.bounds.first?.erasedQualifiedName, "java.lang.Comparable")
    }

    func testSuperclassAndInterfaces() throws {
        let stub = try readFixture("Fixture")
        XCTAssertEqual(stub.superclass?.erasedQualifiedName, "com.penumbra.fixture.AbstractFixture")
        XCTAssertTrue(stub.interfaces.contains { $0.erasedQualifiedName == "java.io.Serializable" })
    }

    func testPublicMethodWithPrimitiveParametersAndNames() throws {
        let stub = try readFixture("Fixture")
        let add = try XCTUnwrap(stub.methods.first { $0.name == "add" })
        XCTAssertEqual(add.parameters.count, 2)
        XCTAssertEqual(add.parameters.map(\.name), ["a", "b"])
        XCTAssertEqual(add.parameters.map(\.type), [.primitive(.int), .primitive(.int)])
        XCTAssertEqual(add.returnType, .primitive(.int))
        XCTAssertTrue(add.modifiers.contains(.publicFlag))
        XCTAssertFalse(add.modifiers.contains(.staticFlag))
    }

    func testGenericMethodWithVarargsAndNestedGenericReturnType() throws {
        let stub = try readFixture("Fixture")
        let group = try XCTUnwrap(stub.methods.first { $0.name == "group" })
        XCTAssertEqual(group.parameters.count, 2)
        // `T key` resolves through the generic signature to a type-variable reference.
        XCTAssertEqual(group.parameters[0].type, .typeVariable(name: "T"))
        // `int... counts` is an int[] at the descriptor/signature level; varargs is a modifier flag.
        if case .array(let element) = group.parameters[1].type {
            XCTAssertEqual(element, .primitive(.int))
        } else {
            XCTFail("expected array type for varargs parameter, got \(group.parameters[1].type)")
        }
        XCTAssertTrue(group.modifiers.contains(.varargs))
        guard case .classType(let qualifiedName, let args, _) = group.returnType else {
            return XCTFail("expected Map<String, List<T>> return type")
        }
        XCTAssertEqual(qualifiedName, "java.util.Map")
        XCTAssertEqual(args.count, 2)
    }

    func testStaticFactoryMethod() throws {
        let stub = try readFixture("Fixture")
        let create = try XCTUnwrap(stub.methods.first { $0.name == "create" })
        XCTAssertTrue(create.modifiers.contains(.staticFlag))
        XCTAssertEqual(create.returnType.erasedQualifiedName, "com.penumbra.fixture.Fixture")
    }

    func testConstructors() throws {
        let stub = try readFixture("Fixture")
        let constructors = stub.methods.filter(\.isConstructor)
        XCTAssertEqual(constructors.count, 2)
        XCTAssertTrue(constructors.contains { $0.parameters.isEmpty })
        XCTAssertTrue(constructors.contains { $0.parameters.count == 2 })
    }

    func testDeprecatedMethodFlag() throws {
        let stub = try readFixture("Fixture")
        let oldMethod = try XCTUnwrap(stub.methods.first { $0.name == "oldMethod" })
        XCTAssertTrue(oldMethod.modifiers.contains(.deprecatedFlag))
    }

    func testFieldsWithModifiersAndGenericType() throws {
        let stub = try readFixture("Fixture")
        let constant = try XCTUnwrap(stub.fields.first { $0.name == "CONSTANT" })
        XCTAssertTrue(constant.modifiers.contains(.staticFlag))
        XCTAssertTrue(constant.modifiers.contains(.finalFlag))
        XCTAssertEqual(constant.type, .primitive(.int))

        let items = try XCTUnwrap(stub.fields.first { $0.name == "items" })
        guard case .classType(let qualifiedName, let args, _) = items.type else {
            return XCTFail("expected List<T> field type")
        }
        XCTAssertEqual(qualifiedName, "java.util.List")
        XCTAssertEqual(args.count, 1)
    }

    func testPrivateFieldExcludedFromPublicAPIOnlyRead() throws {
        // `name` is private; membersPublicAPIOnly (the default, used for library roots) drops it.
        let stub = try readFixture("Fixture")
        XCTAssertNil(stub.fields.first { $0.name == "name" })
    }

    func testPrivateFieldIncludedWhenNotRestrictedToPublicAPI() throws {
        let stub = try readFixture("Fixture", options: ClassFileReadOptions(membersPublicAPIOnly: false))
        XCTAssertNotNil(stub.fields.first { $0.name == "name" })
    }

    func testEnumKind() throws {
        let stub = try readFixture("Fixture$Kind")
        XCTAssertEqual(stub.kind, .enumKind)
        XCTAssertEqual(stub.simpleName, "Kind")
        XCTAssertEqual(stub.outerQualifiedName, "com.penumbra.fixture.Fixture")
        XCTAssertEqual(stub.qualifiedName, "com.penumbra.fixture.Fixture.Kind")
    }

    func testInterfaceKind() throws {
        let stub = try readFixture("Fixture$Listener")
        XCTAssertEqual(stub.kind, .interfaceKind)
        let onEvent = try XCTUnwrap(stub.methods.first { $0.name == "onEvent" })
        XCTAssertTrue(onEvent.modifiers.contains(.abstractFlag) || onEvent.modifiers.contains(.publicFlag))
    }

    func testRecordKind() throws {
        let stub = try readFixture("Fixture$Point")
        XCTAssertEqual(stub.kind, .recordKind)
        // Record accessors are emitted by javac as normal public methods named after the components.
        XCTAssertTrue(stub.methods.contains { $0.name == "x" && $0.parameters.isEmpty })
        XCTAssertTrue(stub.methods.contains { $0.name == "y" && $0.parameters.isEmpty })
    }

    func testNestedStaticClass() throws {
        let stub = try readFixture("Fixture$Nested")
        XCTAssertEqual(stub.kind, .classKind)
        XCTAssertTrue(stub.modifiers.contains(.staticFlag) || stub.outerQualifiedName != nil)
        XCTAssertEqual(stub.outerQualifiedName, "com.penumbra.fixture.Fixture")
    }

    func testAbstractClassWithPackagePrivateAbstractMethod() throws {
        let stub = try readFixture("AbstractFixture", options: ClassFileReadOptions(membersPublicAPIOnly: false))
        XCTAssertTrue(stub.modifiers.contains(.abstractFlag))
        XCTAssertTrue(stub.methods.contains { $0.name == "doWork" })
    }

    func testBadMagicThrows() {
        let junk = Data([0x00, 0x00, 0x00, 0x00])
        XCTAssertThrowsError(try ClassFileReader.read(junk, origin: .jdkModule("test"))) { error in
            guard case ClassFileError.badMagic = error else {
                return XCTFail("expected .badMagic, got \(error)")
            }
        }
    }

    func testTruncatedFileThrows() {
        var bytes = JavaFixtures.classFile("Fixture")
        bytes.removeLast(bytes.count / 2)
        XCTAssertThrowsError(try ClassFileReader.read(bytes, origin: .jdkModule("test")))
    }
}
