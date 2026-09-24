import JavaIntelligence
import XCTest

final class JavaGradleModelDiffTests: XCTestCase {
    func testDetectsAddedJar() throws {
        let base = try loadFixture("single-module")
        let main = base.subprojects[0].sourceSets.first { $0.name == "main" } ?? base.subprojects[0].sourceSets[0]
        let extraJar = URL(fileURLWithPath: "/tmp/extra.jar")
        let updatedMain = JavaGradleProjectModel.SourceSet(
            name: main.name,
            sourceDirs: main.sourceDirs,
            outputDirs: main.outputDirs,
            compileClasspathJars: main.compileClasspathJars + [extraJar],
            projectDependencies: main.projectDependencies,
            runtimeClasspathJars: main.runtimeClasspathJars,
            runtimeProjectDependencies: main.runtimeProjectDependencies,
            generatedSourceDirs: main.generatedSourceDirs,
            annotationProcessorJars: main.annotationProcessorJars
        )
        let changed = JavaGradleProjectModel(
            formatVersion: base.formatVersion,
            gradleVersion: base.gradleVersion,
            subprojects: [
                JavaGradleProjectModel.Subproject(
                    path: base.subprojects[0].path,
                    directory: base.subprojects[0].directory,
                    languageLevel: base.subprojects[0].languageLevel,
                    sourceSets: base.subprojects[0].sourceSets.map { $0.name == "main" ? updatedMain : $0 },
                    tasks: base.subprojects[0].tasks
                )
            ],
            unresolved: base.unresolved
        )
        let diff = JavaGradleProjectModel.diff(old: base, new: changed)
        XCTAssertTrue(diff.addedJars.contains(extraJar))
        XCTAssertFalse(diff.structuralChange)
    }

    func testFirstModelIsStructural() {
        let model = JavaGradleProjectModel(formatVersion: 5, gradleVersion: "8.0", subprojects: [])
        let diff = JavaGradleProjectModel.diff(old: nil, new: model)
        XCTAssertTrue(diff.structuralChange)
    }

    private func loadFixture(_ name: String) throws -> JavaGradleProjectModel {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Gradle/\(name).json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(JavaGradleProjectModel.self, from: data)
    }
}
