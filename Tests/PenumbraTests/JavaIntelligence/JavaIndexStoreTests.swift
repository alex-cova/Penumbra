import XCTest
@testable import JavaIntelligence

final class JavaIndexStoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).idx")
    }

    private func sampleStub(name: String = "com.example.Foo") -> JavaClassStub {
        JavaClassStub(
            binaryName: name,
            qualifiedName: name,
            simpleName: String(name.split(separator: ".").last!),
            packageName: name.components(separatedBy: ".").dropLast().joined(separator: "."),
            kind: .classKind,
            modifiers: [.publicFlag, .finalFlag],
            typeParameters: [JavaTypeParameter(name: "T", bounds: [.classType(qualifiedName: "java.lang.Object", arguments: [], outer: nil)])],
            superclass: .classType(qualifiedName: "java.lang.Object", arguments: [], outer: nil),
            interfaces: [.classType(qualifiedName: "java.io.Serializable", arguments: [], outer: nil)],
            fields: [JavaFieldStub(name: "value", type: .primitive(.int), modifiers: [.privateFlag])],
            methods: [
                JavaMethodStub(
                    name: "get",
                    parameters: [JavaParameterStub(name: "key", type: .classType(qualifiedName: "java.lang.String", arguments: [], outer: nil))],
                    returnType: .array(element: .primitive(.byte)),
                    thrownTypes: [.classType(qualifiedName: "java.io.IOException", arguments: [], outer: nil)],
                    modifiers: [.publicFlag]
                )
            ],
            innerTypeNames: ["com.example.Foo.Bar"],
            origin: .jdkModule("java.base"),
            javadoc: "Does a thing."
        )
    }

    func testRoundTripSingleStub() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let stub = sampleStub()
        let stamp = JavaStamp(size: 1234, modificationDate: 987_654_321)

        try JavaIndexShardWriter().write([stub], stamp: stamp, to: url)
        let reader = try JavaIndexShardReader(url: url)

        XCTAssertEqual(reader.stamp, stamp)
        XCTAssertEqual(reader.allQualifiedNames, ["com.example.Foo"])
        XCTAssertTrue(reader.contains("com.example.Foo"))
        XCTAssertFalse(reader.contains("com.example.Bar"))

        let decoded = try XCTUnwrap(reader.classStub(named: "com.example.Foo"))
        XCTAssertEqual(decoded, stub)
    }

    func testRoundTripManyStubsPreservesEachIndependently() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let stubs = (0..<50).map { sampleStub(name: "com.example.Class\($0)") }
        try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 1, modificationDate: 1), to: url)

        let reader = try JavaIndexShardReader(url: url)
        XCTAssertEqual(reader.allQualifiedNames.count, 50)
        for stub in stubs {
            let decoded = try XCTUnwrap(reader.classStub(named: stub.qualifiedName), "missing \(stub.qualifiedName)")
            XCTAssertEqual(decoded.qualifiedName, stub.qualifiedName)
            XCTAssertEqual(decoded.methods, stub.methods)
        }
    }

    func testEmptyShardRoundTrips() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try JavaIndexShardWriter().write([], stamp: JavaStamp(size: 0, modificationDate: 0), to: url)
        let reader = try JavaIndexShardReader(url: url)
        XCTAssertEqual(reader.allQualifiedNames, [])
        XCTAssertNil(reader.classStub(named: "anything"))
    }

    func testStubsWithNilOptionalFieldsRoundTrip() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let stub = JavaClassStub(
            binaryName: "Bare", qualifiedName: "Bare", simpleName: "Bare", packageName: "",
            kind: .interfaceKind, modifiers: [], origin: .jdkModule("java.base")
        )
        try JavaIndexShardWriter().write([stub], stamp: JavaStamp(size: 0, modificationDate: 0), to: url)
        let reader = try JavaIndexShardReader(url: url)
        let decoded = try XCTUnwrap(reader.classStub(named: "Bare"))
        XCTAssertNil(decoded.outerQualifiedName)
        XCTAssertNil(decoded.superclass)
        XCTAssertNil(decoded.javadoc)
        XCTAssertEqual(decoded.fields, [])
        XCTAssertEqual(decoded.methods, [])
    }

    func testStubWithSourceOriginRoundTrips() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let sourceURL = URL(fileURLWithPath: "/tmp/Foo.java")
        let stub = JavaClassStub(
            binaryName: "Foo", qualifiedName: "Foo", simpleName: "Foo", packageName: "",
            kind: .classKind, modifiers: [.publicFlag],
            origin: .source(sourceURL, nameRange: 10..<13)
        )
        try JavaIndexShardWriter().write([stub], stamp: JavaStamp(size: 0, modificationDate: 0), to: url)
        let reader = try JavaIndexShardReader(url: url)
        let decoded = try XCTUnwrap(reader.classStub(named: "Foo"))
        guard case .source(let url2, let range) = decoded.origin else {
            return XCTFail("expected .source origin")
        }
        XCTAssertEqual(url2, sourceURL)
        XCTAssertEqual(range, 10..<13)
    }

    func testWrongMagicThrows() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("NOTX".utf8).write(to: url)
        XCTAssertThrowsError(try JavaIndexShardReader(url: url)) { error in
            guard case JavaIndexStoreError.badMagic = error else {
                return XCTFail("expected .badMagic, got \(error)")
            }
        }
    }

    func testFutureFormatVersionThrows() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try JavaIndexShardWriter().write([sampleStub()], stamp: JavaStamp(size: 0, modificationDate: 0), to: url)
        var bytes = try Data(contentsOf: url)
        // Bytes 4...8 hold the little-endian format version; bump it to simulate a future format.
        bytes[4] = 0xFF
        try bytes.write(to: url)
        XCTAssertThrowsError(try JavaIndexShardReader(url: url)) { error in
            guard case JavaIndexStoreError.unsupportedFormatVersion = error else {
                return XCTFail("expected .unsupportedFormatVersion, got \(error)")
            }
        }
    }

    func testJavaStampFromRealFileMatchesFileManagerAttributes() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("hello".utf8).write(to: url)
        let stamp = try XCTUnwrap(JavaStamp(url: url))
        XCTAssertEqual(stamp.size, 5)
    }
}
