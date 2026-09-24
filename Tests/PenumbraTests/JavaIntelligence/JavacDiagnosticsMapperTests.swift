import XCTest
import EditorIntelligence
@testable import JavaIntelligence

final class JavacDiagnosticsMapperTests: XCTestCase {
    /// What Gradle prints for a failed `compileJava` across two modules. Tasks and the failure
    /// summary go to the same stream as javac's own text.
    private let gradleOutput = """
    > Task :core:compileJava
    /work/core/src/main/java/demo/Model.java:7: error: cannot find symbol
            Strin name;
            ^
      symbol:   class Strin
      location: class Model
    /work/core/src/main/java/demo/Model.java:12: warning: [deprecation] old() in Legacy has been deprecated
            Legacy.old();
                  ^
    Note: Some input files use unchecked or unsafe operations.
    1 error
    1 warning

    > Task :core:compileJava FAILED
    > Task :app:compileJava
    /work/app/src/main/java/demo/Main.java:3: error: ';' expected
            int x = 1
                     ^
    1 error

    FAILURE: Build failed with an exception.

    * What went wrong:
    Execution failed for task ':core:compileJava'.
    > Compilation failed; see the compiler error output for details.

    BUILD FAILED in 2s
    """

    private let model = "package demo;\n\nclass Model {\n    int a;\n    int b;\n    int c;\n        Strin name;\n    int d;\n    int e;\n    int f;\n    int g;\n        Legacy.old();\n}\n"

    func testGroupsMessagesByFileAndKeepsSeverityAndCategory() throws {
        let messages = JavacOutputParser.parse(gradleOutput)
        let result = JavacDiagnosticsMapper.diagnostics(from: messages, source: "gradle") { url in
            url.lastPathComponent == "Model.java" ? self.model : nil
        }
        XCTAssertEqual(Set(result.keys.map(\.lastPathComponent)), ["Model.java", "Main.java"])

        let modelFile = try XCTUnwrap(result.first { $0.key.lastPathComponent == "Model.java" }?.value)
        XCTAssertEqual(modelFile.map(\.severity), [.error, .warning])
        XCTAssertEqual(modelFile.map(\.source), ["gradle", "gradle"])
        XCTAssertTrue(modelFile[0].message.hasPrefix("cannot find symbol"))
        XCTAssertEqual(modelFile[1].code, "deprecation")
        XCTAssertEqual(modelFile[0].range.start.line, 6)
        // The caret column selects the identifier at that column in the real text.
        let range = ProblemLocator.nsRange(for: modelFile[0].range, in: model)
        XCTAssertEqual((model as NSString).substring(with: range), "Strin")
    }

    func testFileWithoutReadableTextKeepsPrintedLineAndColumn() throws {
        let messages = JavacOutputParser.parse(gradleOutput)
        let result = JavacDiagnosticsMapper.diagnostics(from: messages, source: "gradle") { _ in nil }
        let main = try XCTUnwrap(result.first { $0.key.lastPathComponent == "Main.java" }?.value.first)
        XCTAssertEqual(main.range.start.line, 2)
        XCTAssertEqual(main.range.start.column, 17)
        XCTAssertEqual(main.severity, .error)
    }

    func testMessagesWithoutAFileAreDropped() {
        let messages = JavacOutputParser.parse("error: release version 99 not supported\n1 error\n")
        XCTAssertEqual(messages.count, 1)
        let result = JavacDiagnosticsMapper.diagnostics(from: messages, source: "gradle") { _ in "" }
        XCTAssertTrue(result.isEmpty)
    }

    func testRelativePathsResolveAgainstTheBaseDirectory() {
        let messages = [JavacMessage(file: "src/main/java/A.java", line: 1, column: 0, severity: .error, message: "boom")]
        let base = URL(fileURLWithPath: "/work/app", isDirectory: true)
        let result = JavacDiagnosticsMapper.diagnostics(from: messages, source: "gradle", baseDirectory: base) { _ in "class A {}" }
        XCTAssertEqual(result.keys.map(\.path), ["/work/app/src/main/java/A.java"])
    }

    func testNoisyOutputWithoutCompilerMessagesYieldsNothing() {
        let output = "> Task :app:test FAILED\n\nFAILURE: Build failed with an exception.\n* What went wrong:\nExecution failed.\n"
        let messages = JavacOutputParser.parse(output)
        XCTAssertTrue(JavacDiagnosticsMapper.diagnostics(from: messages, source: "gradle") { _ in nil }.isEmpty)
    }
}
