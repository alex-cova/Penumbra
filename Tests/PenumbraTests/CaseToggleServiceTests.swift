import XCTest
@testable import Penumbra

final class CaseToggleServiceTests: XCTestCase {
    func testCyclesLowerUpperTitle() {
        XCTAssertEqual(CaseToggleService.toggled("hello"), "HELLO")
        XCTAssertEqual(CaseToggleService.toggled("HELLO"), "Hello")
        XCTAssertEqual(CaseToggleService.toggled("Hello"), "hello")
    }

    func testCyclesMultipleWords() {
        XCTAssertEqual(CaseToggleService.toggled("hello world"), "HELLO WORLD")
        XCTAssertEqual(CaseToggleService.toggled("HELLO WORLD"), "Hello World")
        XCTAssertEqual(CaseToggleService.toggled("Hello World"), "hello world")
    }

    func testPreservesNonLetters() {
        XCTAssertEqual(CaseToggleService.toggled("foo_bar"), "FOO_BAR")
        XCTAssertEqual(CaseToggleService.toggled("FOO_BAR"), "Foo_Bar")
        XCTAssertEqual(CaseToggleService.toggled("Foo_Bar"), "foo_bar")
    }

    func testMixedCaseStartsAsLowerThenUpper() {
        XCTAssertEqual(CaseToggleService.toggled("HeLLo"), "HELLO")
    }
}
