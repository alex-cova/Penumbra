import XCTest
@testable import JavaIntelligence

final class DescriptorParserTests: XCTestCase {
    func testPrimitiveFieldDescriptors() {
        XCTAssertEqual(DescriptorParser.parseFieldDescriptor("I"), .primitive(.int))
        XCTAssertEqual(DescriptorParser.parseFieldDescriptor("Z"), .primitive(.boolean))
        XCTAssertEqual(DescriptorParser.parseFieldDescriptor("B"), .primitive(.byte))
        XCTAssertEqual(DescriptorParser.parseFieldDescriptor("C"), .primitive(.char))
        XCTAssertEqual(DescriptorParser.parseFieldDescriptor("D"), .primitive(.double))
        XCTAssertEqual(DescriptorParser.parseFieldDescriptor("F"), .primitive(.float))
        XCTAssertEqual(DescriptorParser.parseFieldDescriptor("J"), .primitive(.long))
        XCTAssertEqual(DescriptorParser.parseFieldDescriptor("S"), .primitive(.short))
    }

    func testObjectFieldDescriptor() {
        let type = DescriptorParser.parseFieldDescriptor("Ljava/lang/String;")
        XCTAssertEqual(type?.erasedQualifiedName, "java.lang.String")
    }

    func testArrayFieldDescriptor() {
        let type = DescriptorParser.parseFieldDescriptor("[I")
        guard case .array(let element) = type else { return XCTFail("expected array") }
        XCTAssertEqual(element, .primitive(.int))
    }

    func testMultiDimensionalArrayOfObjects() {
        let type = DescriptorParser.parseFieldDescriptor("[[Ljava/lang/String;")
        guard case .array(let outer) = type, case .array(let inner) = outer else {
            return XCTFail("expected 2D array")
        }
        XCTAssertEqual(inner.erasedQualifiedName, "java.lang.String")
    }

    func testMethodDescriptorWithMixedParameters() {
        let decoded = DescriptorParser.parseMethodDescriptor("(ILjava/lang/String;[I)Z")
        let result = try? XCTUnwrap(decoded)
        XCTAssertEqual(result?.parameters.count, 3)
        XCTAssertEqual(result?.parameters[0], .primitive(.int))
        XCTAssertEqual(result?.parameters[1].erasedQualifiedName, "java.lang.String")
        XCTAssertEqual(result?.returnType, .primitive(.boolean))
    }

    func testVoidMethodDescriptor() {
        let decoded = DescriptorParser.parseMethodDescriptor("()V")
        XCTAssertEqual(decoded?.parameters.count, 0)
        XCTAssertEqual(decoded?.returnType, .void)
    }

    func testMalformedDescriptorReturnsNil() {
        XCTAssertNil(DescriptorParser.parseFieldDescriptor("Q"))
        XCTAssertNil(DescriptorParser.parseMethodDescriptor("(I"))
    }
}
