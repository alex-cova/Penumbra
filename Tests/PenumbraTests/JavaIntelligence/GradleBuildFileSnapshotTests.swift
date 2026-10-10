import XCTest
@testable import JavaIntelligence

final class GradleBuildFileSnapshotTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write("plugins { id 'java' }", to: "build.gradle")
        try write("rootProject.name = 'demo'", to: "settings.gradle")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCapturesBuildInputsOnly() throws {
        try write("generated", to: "build/build.gradle")
        try write("class Main {}", to: "src/Main.java")
        let snapshot = GradleBuildFileSnapshot.capture(projectRoot: root)
        XCTAssertEqual(Set(snapshot.contents.keys), ["build.gradle", "settings.gradle"])
    }

    func testRewritingTheSameBytesIsNotADifference() throws {
        let snapshot = GradleBuildFileSnapshot.capture(projectRoot: root)
        try write("plugins { id 'java' }", to: "build.gradle")
        let later = Date().addingTimeInterval(60)
        try FileManager.default.setAttributes(
            [.modificationDate: later], ofItemAtPath: root.appendingPathComponent("build.gradle").path
        )
        XCTAssertFalse(snapshot.differs(relativePath: "build.gradle", projectRoot: root))
    }

    func testAnEditIsADifferenceAndRevertingItIsNot() throws {
        let snapshot = GradleBuildFileSnapshot.capture(projectRoot: root)
        try write("plugins { id 'java' }\n// edited", to: "build.gradle")
        XCTAssertTrue(snapshot.differs(relativePath: "build.gradle", projectRoot: root))
        try write("plugins { id 'java' }", to: "build.gradle")
        XCTAssertFalse(snapshot.differs(relativePath: "build.gradle", projectRoot: root))
    }

    func testAddedAndDeletedFilesAreDifferences() throws {
        let snapshot = GradleBuildFileSnapshot.capture(projectRoot: root)
        try write("plugins {}", to: "app/build.gradle")
        XCTAssertTrue(snapshot.differs(relativePath: "app/build.gradle", projectRoot: root))
        try FileManager.default.removeItem(at: root.appendingPathComponent("settings.gradle"))
        XCTAssertTrue(snapshot.differs(relativePath: "settings.gradle", projectRoot: root))
    }

    func testAFileThatNeverExistedIsNotADifference() {
        let snapshot = GradleBuildFileSnapshot.capture(projectRoot: root)
        XCTAssertFalse(snapshot.differs(relativePath: "missing/build.gradle", projectRoot: root))
    }

    private func write(_ text: String, to relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
