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
}
