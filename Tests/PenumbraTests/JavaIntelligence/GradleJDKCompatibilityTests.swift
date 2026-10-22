import XCTest
@testable import JavaIntelligence

final class GradleJDKCompatibilityTests: XCTestCase {
    func testMaximumJavaVersionByGradleRelease() {
        XCTAssertEqual(GradleJDKCompatibility.maximumJavaVersion(forGradle: "7.6.4"), 19)
        XCTAssertEqual(GradleJDKCompatibility.maximumJavaVersion(forGradle: "8.5"), 21)
        XCTAssertEqual(GradleJDKCompatibility.maximumJavaVersion(forGradle: "8.9"), 22)
        XCTAssertEqual(GradleJDKCompatibility.maximumJavaVersion(forGradle: "8.14.3"), 24)
        XCTAssertEqual(GradleJDKCompatibility.maximumJavaVersion(forGradle: "8.10-rc-1"), 23)
        XCTAssertEqual(GradleJDKCompatibility.maximumJavaVersion(forGradle: "9.1"), 25)
        XCTAssertEqual(GradleJDKCompatibility.maximumJavaVersion(forGradle: "9.3"), 25)
        // The newest release the table knows still has a cap: Gradle 9.4 runs on Java 26 at
        // most, so a newer installed JDK (27) must not be picked for it.
        XCTAssertEqual(GradleJDKCompatibility.maximumJavaVersion(forGradle: "9.4"), 26)
        XCTAssertEqual(GradleJDKCompatibility.maximumJavaVersion(forGradle: "9.4.1"), 26)
    }

    func testUnreadableOrNewerThanKnownGradleIsUnbounded() {
        XCTAssertNil(GradleJDKCompatibility.maximumJavaVersion(forGradle: "banana"))
        XCTAssertNil(GradleJDKCompatibility.maximumJavaVersion(forGradle: "9.5"))
        XCTAssertNil(GradleJDKCompatibility.maximumJavaVersion(forGradle: "10.0"))
    }

    func testUnsupportedClassFileMajorVersionIsDetectedInStderrOrStdout() {
        let stderr = GradleCommandResult(exitCode: 1, stdout: "", stderr: "BUG! Unsupported class file major version 71")
        XCTAssertEqual(GradleJDKCompatibility.unsupportedClassFileMajorVersion(in: stderr), 71)
        let stdout = GradleCommandResult(exitCode: 1, stdout: "Unsupported class file major version 65", stderr: "")
        XCTAssertEqual(GradleJDKCompatibility.unsupportedClassFileMajorVersion(in: stdout), 65)
    }

    func testUnsupportedClassFileMajorVersionIgnoresOtherFailures() {
        let unrelated = GradleCommandResult(exitCode: 1, stdout: "", stderr: "Compilation failed")
        XCTAssertNil(GradleJDKCompatibility.unsupportedClassFileMajorVersion(in: unrelated))
        let noVersion = GradleCommandResult(exitCode: 1, stdout: "", stderr: "Unsupported class file major version")
        XCTAssertNil(GradleJDKCompatibility.unsupportedClassFileMajorVersion(in: noVersion))
        let success = GradleCommandResult(exitCode: 0, stdout: "Unsupported class file major version 71", stderr: "")
        XCTAssertNil(GradleJDKCompatibility.unsupportedClassFileMajorVersion(in: success))
    }

    func testWrapperVersionFromDistributionUrl() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("gradle/wrapper")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "distributionUrl=https\\://services.gradle.org/distributions/gradle-8.5-bin.zip\n"
            .write(to: dir.appendingPathComponent("gradle-wrapper.properties"), atomically: true, encoding: .utf8)
        XCTAssertEqual(GradleJDKCompatibility.wrapperVersion(in: root), "8.5")
        XCTAssertEqual(GradleJDKCompatibility.maximumJavaVersion(forProject: root), 21)
        XCTAssertNil(GradleJDKCompatibility.wrapperVersion(in: root.appendingPathComponent("missing")))
    }
}
