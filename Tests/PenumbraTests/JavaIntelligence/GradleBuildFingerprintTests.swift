import XCTest
@testable import JavaIntelligence

final class GradleBuildFingerprintTests: XCTestCase {
    func testCollectsRootBuildScripts() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        try "root project".write(to: root.appendingPathComponent("settings.gradle"), atomically: true, encoding: .utf8)
        try "plugins { id 'java' }".write(to: root.appendingPathComponent("build.gradle"), atomically: true, encoding: .utf8)
        try "org.gradle.jvmargs=-Xmx1g".write(to: root.appendingPathComponent("gradle.properties"), atomically: true, encoding: .utf8)

        let fingerprint = GradleBuildFingerprintCollector.collect(projectRoot: root)
        XCTAssertEqual(fingerprint.scriptFormatVersion, GradleProjectModelScript.formatVersion)
        XCTAssertEqual(Set(fingerprint.files.map(\.relativePath)), Set([
            "settings.gradle",
            "build.gradle",
            "gradle.properties"
        ]))
    }

    func testCollectsSubprojectBuildScriptsAndVersionCatalog() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        try "root project".write(to: root.appendingPathComponent("settings.gradle"), atomically: true, encoding: .utf8)
        let appDir = root.appendingPathComponent("app", isDirectory: true)
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        try "plugins { id 'java' }".write(to: appDir.appendingPathComponent("build.gradle.kts"), atomically: true, encoding: .utf8)

        let gradleDir = root.appendingPathComponent("gradle", isDirectory: true)
        try FileManager.default.createDirectory(at: gradleDir, withIntermediateDirectories: true)
        try "[versions]\nfoo = \"1.0\"".write(
            to: gradleDir.appendingPathComponent("libs.versions.toml"),
            atomically: true,
            encoding: .utf8
        )
        let wrapperDir = gradleDir.appendingPathComponent("wrapper", isDirectory: true)
        try FileManager.default.createDirectory(at: wrapperDir, withIntermediateDirectories: true)
        try "distributionUrl=https://services.gradle.org/distributions/gradle-9.2.1-bin.zip".write(
            to: wrapperDir.appendingPathComponent("gradle-wrapper.properties"),
            atomically: true,
            encoding: .utf8
        )

        let fingerprint = GradleBuildFingerprintCollector.collect(projectRoot: root)
        XCTAssertEqual(Set(fingerprint.files.map(\.relativePath)), Set([
            "settings.gradle",
            "app/build.gradle.kts",
            "gradle/libs.versions.toml",
            "gradle/wrapper/gradle-wrapper.properties"
        ]))
    }

    func testFingerprintChangesWhenBuildFileChanges() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let buildFile = root.appendingPathComponent("build.gradle")
        try "v1".write(to: buildFile, atomically: true, encoding: .utf8)
        let first = GradleBuildFingerprintCollector.collect(projectRoot: root)

        try "v2".write(to: buildFile, atomically: true, encoding: .utf8)
        let second = GradleBuildFingerprintCollector.collect(projectRoot: root)

        XCTAssertNotEqual(first, second)
    }

    func testFingerprintIgnoresBuildOutputDirectories() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        try "root project".write(to: root.appendingPathComponent("settings.gradle"), atomically: true, encoding: .utf8)
        let buildDir = root.appendingPathComponent("build", isDirectory: true)
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
        try "generated".write(to: buildDir.appendingPathComponent("build.gradle"), atomically: true, encoding: .utf8)

        let fingerprint = GradleBuildFingerprintCollector.collect(projectRoot: root)
        XCTAssertEqual(fingerprint.files.map(\.relativePath), ["settings.gradle"])
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
