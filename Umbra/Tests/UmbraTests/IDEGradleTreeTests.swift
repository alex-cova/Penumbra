import Foundation
import JavaIntelligence
import XCTest
@testable import Umbra

final class IDEGradleTreeTests: XCTestCase {
    func testDependenciesAreSortedByDisplayedTitle() throws {
        let model = JavaGradleProjectModel(
            formatVersion: 9,
            gradleVersion: "9.0",
            subprojects: [
                .init(path: ":", directory: URL(fileURLWithPath: "/tmp/project"), sourceSets: [
                    .init(name: "test", compileClasspathJars: [URL(fileURLWithPath: "/tmp/test.jar")]),
                    .init(
                        name: "main",
                        compileClasspathJars: [
                            URL(fileURLWithPath: "/tmp/Zulu.jar"),
                            URL(fileURLWithPath: "/tmp/files-2.1/com.example/library/1.0/hash/library.jar")
                        ],
                        projectDependencies: [.init(projectPath: ":lib", sourceSetName: "main")]
                    )
                ])
            ],
            unresolved: ["Zulu", "alpha"]
        )

        let root = try XCTUnwrap(IDEGradleTree.build(from: model))
        let dependencies = try XCTUnwrap(root.children.first { $0.title == "Dependencies" })
        XCTAssertEqual(dependencies.children.map(\.title), ["compileClasspath", "testCompileClasspath", "Unresolved"])
        XCTAssertEqual(dependencies.children.first?.children.map(\.title), [
            "com.example:library:1.0", "project :lib", "Zulu.jar"
        ])
        XCTAssertEqual(dependencies.children.last?.children.map(\.title), ["alpha", "Zulu"])
    }
}
