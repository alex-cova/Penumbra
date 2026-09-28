import XCTest
@testable import JavaIntelligence

final class JavaCaretContextTests: XCTestCase {
    private let source = """
    package demo;

    public class Hello {
        int field = 1;

        Hello() {
        }

        static class Inner {
            void work() {
                int a = 1;
            }
        }

        public static void main(String[] args) {
            System.out.println("hi");
        }
    }
    """

    private func context(at marker: String, offsetInMarker: Int = 0) async throws -> JavaCaretContext? {
        let range = try XCTUnwrap(source.range(of: marker))
        let caret = source.utf16.distance(from: source.startIndex, to: range.lowerBound) + offsetInMarker
        return await JavaStructureProvider().caretContext(in: source, atUTF16Offset: caret)
    }

    func testCaretInsideAMethodBodyNamesTheMethodAndItsLine() async throws {
        let inside = try await context(at: "System.out")
        XCTAssertEqual(inside, JavaCaretContext(typeName: "Hello", methodName: "main", methodNameLine: 15))
    }

    func testCaretOnTheMethodNameCounts() async throws {
        let onName = try await context(at: "main(String", offsetInMarker: 2)
        XCTAssertEqual(onName?.methodName, "main")
    }

    func testCaretInAFieldHasNoMethod() async throws {
        let inField = try await context(at: "int field")
        XCTAssertEqual(inField, JavaCaretContext(typeName: "Hello", methodName: nil, methodNameLine: nil))
    }

    func testCaretInANestedTypeReportsTheNestedType() async throws {
        let nested = try await context(at: "int a = 1")
        XCTAssertEqual(nested, JavaCaretContext(typeName: "Inner", methodName: "work", methodNameLine: 10))
    }

    func testAConstructorIsNotAMethod() async throws {
        let constructor = try await context(at: "Hello() {", offsetInMarker: 8)
        XCTAssertNil(constructor?.methodName)
    }

    func testNoTypeMeansNoContext() async {
        let none = await JavaStructureProvider().caretContext(in: "// nothing here\n", atUTF16Offset: 3)
        XCTAssertNil(none)
    }
}
