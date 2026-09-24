import XCTest
@testable import JavaIntelligence

final class JavacOutputParserTests: XCTestCase {
    func testParsesErrorWithCaretDetailsAndSummary() {
        let output = """
        /work/Foo.java:5: error: cannot find symbol
                Strin x;
                ^
          symbol:   class Strin
          location: class Foo
        1 error
        """
        let messages = JavacOutputParser.parse(output)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].file, "/work/Foo.java")
        XCTAssertEqual(messages[0].line, 5)
        XCTAssertEqual(messages[0].column, 8)
        XCTAssertEqual(messages[0].severity, .error)
        XCTAssertEqual(messages[0].message, "cannot find symbol\nsymbol:   class Strin\nlocation: class Foo")
    }

    func testParsesSeveralMessagesAndWarnings() {
        let output = """
        /work/Foo.java:3: warning: [deprecation] old() in Foo has been deprecated
            old();
            ^
        /work/Foo.java:9: error: ';' expected
            int x = 1
                     ^
        1 error
        1 warning
        """
        let messages = JavacOutputParser.parse(output)
        XCTAssertEqual(messages.map(\.severity), [.warning, .error])
        XCTAssertEqual(messages.map(\.line), [3, 9])
        XCTAssertEqual(messages.map(\.column), [4, 13])
        XCTAssertEqual(messages[1].message, "';' expected")
    }

    func testCaretColumnCountsTabsAsOneCharacter() {
        let output = "/work/Foo.java:2: error: boom\n\t\tfoo();\n\t\t^\n1 error\n"
        XCTAssertEqual(JavacOutputParser.parse(output).first?.column, 2)
    }

    func testMessageContinuationBeforeSourceLine() {
        let output = """
        /work/Foo.java:4: error: incompatible types: possible lossy conversion
          from double to int
            int x = 1.5;
                    ^
        1 error
        """
        let message = JavacOutputParser.parse(output).first
        XCTAssertEqual(message?.message, "incompatible types: possible lossy conversion\nfrom double to int")
        XCTAssertEqual(message?.column, 12)
    }

    func testMessageWithoutCaretHasNoColumn() {
        let output = "/work/Foo.java:1: error: class Bar is public, should be declared in a file named Bar.java\n1 error\n"
        let message = JavacOutputParser.parse(output).first
        XCTAssertEqual(message?.line, 1)
        XCTAssertNil(message?.column)
    }

    func testFilelessMessagesAndNoise() {
        let output = """
        Picked up JAVA_TOOL_OPTIONS: -Xmx1g
        error: release version 99 not supported
        warning: [options] something
        Note: Foo.java uses unchecked or unsafe operations.
        Note: Recompile with -Xlint:unchecked for details.
        1 error
        1 warning
        """
        let messages = JavacOutputParser.parse(output)
        XCTAssertEqual(messages.count, 2)
        XCTAssertNil(messages[0].file)
        XCTAssertEqual(messages[0].severity, .error)
        XCTAssertEqual(messages[0].message, "release version 99 not supported")
        XCTAssertEqual(messages[1].severity, .warning)
    }

    func testCleanOutputHasNoMessages() {
        XCTAssertTrue(JavacOutputParser.parse("").isEmpty)
        XCTAssertTrue(JavacOutputParser.parse("Note: Foo.java uses unchecked or unsafe operations.\n").isEmpty)
    }

    func testCRLFOutput() {
        let output = "/work/Foo.java:1: error: boom\r\nfoo\r\n^\r\n1 error\r\n"
        XCTAssertEqual(JavacOutputParser.parse(output).first?.column, 0)
    }
}
