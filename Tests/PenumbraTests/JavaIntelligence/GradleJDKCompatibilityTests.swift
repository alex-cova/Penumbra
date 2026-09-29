import XCTest
@testable import JavaIntelligence

final class GradleJDKCompatibilityTests: XCTestCase {
    func testMaximumJavaVersionByGradleRelease() {
        XCTAssertEqual(GradleJDKCompatibility.maximumJavaVersion(forGradle: "7.6.4"), 19)
        XCTAssertEqual(GradleJDKCompatibility.maximumJavaVersion(forGradle: "8.5"), 21)
        XCTAssertEqual(GradleJDKCompatibility.maximumJavaVersion(forGradle: "8.9"), 22)
        XCTAssertEqual(GradleJDKCompatibility.maximumJavaVersion(forGradle: "8.14.3"), 24)
        XCTAssertEqual(GradleJDKCompatibility.maximumJavaVersion(forGradle: "8.10-rc-1"), 23)
    }

    func testUnreadableOrNewestGradleIsUnbounded() {
        XCTAssertNil(GradleJDKCompatibility.maximumJavaVersion(forGradle: "banana"))
        XCTAssertNil(GradleJDKCompatibility.maximumJavaVersion(forGradle: "9.4"))
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
