import Foundation
import XCTest
@testable import JavaIntelligence

/// `JavaSymbol`: names and identities for every declaration kind.
final class JavaSymbolTests: XCTestCase {
    private let file = URL(fileURLWithPath: "/proj/Foo.java")

    func testLocalNameAndID() {
        let symbol = JavaSymbol.local(name: "x", file: file, declarationRange: 10..<11, type: .unresolved(simpleName: "String", arguments: []))
        XCTAssertEqual(symbol.name, "x")
        XCTAssertEqual(symbol.id, .local(file: file, declarationRange: 10..<11))
    }

    func testParameterSharesLocalIdentity() {
        let symbol = JavaSymbol.parameter(
            name: "value", file: file, declarationRange: 20..<25,
            type: .primitive(.int))
        XCTAssertEqual(symbol.name, "value")
        XCTAssertEqual(symbol.id, .local(file: file, declarationRange: 20..<25))
    }

    func testMemberIDs() {
        let method = JavaMethodStub(
            name: "convert", parameters: [JavaParameterStub(name: "value", type: .primitive(.int))],
            returnType: .unresolved(simpleName: "String", arguments: []), thrownTypes: [],
            modifiers: [.publicFlag], isConstructor: false)
        let symbol = JavaSymbol.method(declaringClass: "com.example.D", stub: method)
        XCTAssertEqual(symbol.name, "convert")
        XCTAssertEqual(symbol.id, .method(declaringClass: "com.example.D", name: "convert", parameterKeys: ["int"]))

        let field = JavaFieldStub(name: "count", type: .primitive(.int), modifiers: [])
        XCTAssertEqual(
            JavaSymbol.field(declaringClass: "com.example.Foo", stub: field).id,
            .field(declaringClass: "com.example.Foo", name: "count"))
    }

    func testTypeAndLocalTypeIDs() {
        let stub = JavaClassStub(
            binaryName: "com.example.Foo", qualifiedName: "com.example.Foo", simpleName: "Foo",
            packageName: "com.example", kind: .classKind, modifiers: [], origin: .jdkModule("java.base"))
        XCTAssertEqual(
            JavaSymbol.type(stub: stub).id, .type(qualifiedName: "com.example.Foo"))

        // A local class has no qualified name: file plus declaration site identifies it.
        let local = JavaSymbol.localType(name: "Helper", file: file, declarationRange: 30..<36)
        XCTAssertEqual(local.name, "Helper")
        XCTAssertEqual(local.id, .localType(file: file, declarationRange: 30..<36))
        XCTAssertEqual(JavaSymbolID.localType(file: file, declarationRange: 30..<36).simpleName, "")
        XCTAssertNil(JavaSymbolID.localType(file: file, declarationRange: 30..<36).declaringClass)
    }

    func testUnidentifiedKinds() {
        XCTAssertNil(JavaSymbol.typeParameter(name: "T", owner: nil).id)
        XCTAssertNil(JavaSymbol.package(name: "com.example").id)
        XCTAssertNil(JavaSymbol.label(name: "outer", file: file, declarationRange: 1..<6).id)
        XCTAssertEqual(JavaSymbol.label(name: "outer", file: file, declarationRange: 1..<6).name, "outer")
    }
}
