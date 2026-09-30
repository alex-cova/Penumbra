import XCTest
@testable import JavaIntelligence

final class JavaJarCachePolicyTests: XCTestCase {
    private func isImmutable(_ path: String) -> Bool {
        JavaJarCachePolicy.isImmutableArtifact(URL(fileURLWithPath: path))
    }

    func testReleaseArtifactsInTheGradleCacheAreImmutable() {
        XCTAssertTrue(isImmutable("/Users/a/.gradle/caches/modules-2/files-2.1/com.google.guava/guava/33.0.0-jre/0a1b/guava-33.0.0-jre.jar"))
    }

    func testReleaseArtifactsInTheMavenRepositoryAreImmutable() {
        XCTAssertTrue(isImmutable("/Users/a/.m2/repository/junit/junit/4.13.2/junit-4.13.2.jar"))
    }

    func testSnapshotsAreNotImmutableInEitherCache() {
        XCTAssertFalse(isImmutable("/Users/a/.gradle/caches/modules-2/files-2.1/com.acme/lib/1.0-SNAPSHOT/0a1b/lib-1.0-SNAPSHOT.jar"))
        XCTAssertFalse(isImmutable("/Users/a/.m2/repository/com/acme/lib/1.0-snapshot/lib-1.0-snapshot.jar"))
    }

    func testLocalAndBuildOutputJarsAreNotImmutable() {
        XCTAssertFalse(isImmutable("/Users/a/project/libs/vendor.jar"))
        XCTAssertFalse(isImmutable("/Users/a/project/module/build/libs/module.jar"))
        XCTAssertFalse(isImmutable("/Users/a/.gradle/caches/jars-9/abc/generated.jar"))
    }
}
