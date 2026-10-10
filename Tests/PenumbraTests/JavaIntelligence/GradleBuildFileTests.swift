import XCTest
@testable import JavaIntelligence

final class GradleBuildFileTests: XCTestCase {
    func testMatchesGradleBuildFiles() {
        XCTAssertTrue(GradleBuildFiles.matches(path: "/proj/build.gradle"))
        XCTAssertTrue(GradleBuildFiles.matches(path: "/proj/app/build.gradle.kts"))
        XCTAssertTrue(GradleBuildFiles.matches(path: "/proj/settings.gradle"))
        XCTAssertTrue(GradleBuildFiles.matches(path: "/proj/settings.gradle.kts"))
        XCTAssertTrue(GradleBuildFiles.matches(path: "/proj/gradle.properties"))
        XCTAssertTrue(GradleBuildFiles.matches(path: "/proj/gradle/libs.versions.toml"))
        XCTAssertTrue(GradleBuildFiles.matches(path: "/proj/gradle/wrapper/gradle-wrapper.properties"))
    }

    func testSkipsSourcesGeneratedOutputAndUnrelatedToml() {
        XCTAssertFalse(GradleBuildFiles.matches(path: "/proj/src/main/java/Foo.java"))
        XCTAssertFalse(GradleBuildFiles.matches(path: "/proj/build/build.gradle"))
        XCTAssertFalse(GradleBuildFiles.matches(path: "/proj/app/build/generated/sources/build.gradle"))
        XCTAssertFalse(GradleBuildFiles.matches(path: "/proj/.gradle/8.10/gc.properties"))
        XCTAssertFalse(GradleBuildFiles.matches(path: "/proj/.gradle/configuration-cache/build.gradle"))
        XCTAssertFalse(GradleBuildFiles.matches(path: "/proj/other/libs.versions.toml"))
        XCTAssertFalse(GradleBuildFiles.matches(path: "/proj/gradle-wrapper.properties"))
        XCTAssertFalse(GradleBuildFiles.matches(path: "/proj/notes.txt"))
    }

    func testRelativePathsSkipDependencyFoldersAndHiddenFolders() {
        XCTAssertFalse(GradleBuildFiles.isBuildInput(relativePath: "node_modules/pkg/android/build.gradle"))
        XCTAssertFalse(GradleBuildFiles.isBuildInput(relativePath: "out/production/build.gradle"))
        XCTAssertFalse(GradleBuildFiles.isBuildInput(relativePath: ".github/build.gradle"))
        XCTAssertFalse(GradleBuildFiles.isBuildInput(relativePath: ".idea/gradle.properties"))
        XCTAssertFalse(GradleBuildFiles.isBuildInput(relativePath: "app/build/build.gradle"))
        XCTAssertTrue(GradleBuildFiles.isBuildInput(relativePath: "buildSrc/build.gradle.kts"))
        XCTAssertTrue(GradleBuildFiles.isBuildInput(relativePath: "gradle/libs.versions.toml"))
        XCTAssertFalse(GradleBuildFiles.isBuildInput(relativePath: "libs.versions.toml"))
        XCTAssertTrue(GradleBuildFiles.isBuildInput(relativePath: "gradle/wrapper/gradle-wrapper.properties"))
        XCTAssertFalse(GradleBuildFiles.isBuildInput(relativePath: "wrapper/gradle-wrapper.properties"))
    }

    /// A project that lives under a folder called `build` (or a hidden one) is still watched: only
    /// the part below the root counts.
    func testAProjectUnderABuildFolderIsStillWatched() {
        let root = "/Users/me/build/myapp"
        XCTAssertTrue(GradleBuildFiles.matches(path: root + "/build.gradle", root: root))
        XCTAssertTrue(GradleBuildFiles.matches(path: root + "/app/build.gradle.kts", root: root))
        XCTAssertFalse(GradleBuildFiles.matches(path: root + "/app/build/build.gradle", root: root))
        XCTAssertFalse(GradleBuildFiles.matches(path: "/Users/me/build/other/build.gradle", root: root))
        XCTAssertTrue(GradleBuildFiles.matches(path: "/Users/me/.work/app/build.gradle", root: "/Users/me/.work/app"))
    }

    /// FSEvents reports `/private/var/…` for a file under `/var/…`; `resolvingSymlinksInPath()` turns
    /// that back into `/var`, which made every event of a temporary-folder project fall outside the
    /// root. The canonical root must be what FSEvents would print.
    func testCanonicalRootPathResolvesSymlinksTheWayFSEventsReportsThem() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let target = base.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let fromLink = GradleBuildFiles.canonicalRootPath(for: link)
        XCTAssertEqual(fromLink, GradleBuildFiles.canonicalRootPath(for: target))
        XCTAssertTrue(fromLink.hasSuffix("/real"), fromLink)
        XCTAssertFalse(fromLink.contains("/link"))
        // The temporary directory itself lives behind /var -> /private/var.
        XCTAssertTrue(GradleBuildFiles.canonicalRootPath(for: base).hasPrefix("/private/var/"))
        XCTAssertTrue(GradleBuildFiles.matches(path: fromLink + "/build.gradle", root: fromLink))
    }

    func testInputPathsWalksTheSameFilesTheRuleAccepts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = [
            "settings.gradle", "app/build.gradle.kts", "gradle/libs.versions.toml",
            "node_modules/pkg/build.gradle", "build/build.gradle", ".git/gradle.properties", "src/Main.java"
        ]
        for file in files {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "x".write(to: url, atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(
            GradleBuildFiles.inputPaths(under: root),
            ["app/build.gradle.kts", "gradle/libs.versions.toml", "settings.gradle"]
        )
    }
}
