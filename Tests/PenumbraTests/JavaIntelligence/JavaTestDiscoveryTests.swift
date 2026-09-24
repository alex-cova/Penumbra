import XCTest
@testable import JavaIntelligence

final class JavaTestDiscoveryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("disc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = base.resolvingSymlinksInPath()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private var testDir: URL { root.appendingPathComponent("src/test/java") }

    @discardableResult
    private func write(_ name: String, _ body: String) throws -> URL {
        let url = testDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func classSource(_ name: String) -> String {
        "import org.junit.jupiter.api.Test;\nclass \(name) { @Test void t() {} }"
    }

    private func makeModel() -> JavaGradleProjectModel {
        let main = JavaGradleProjectModel.SourceSet(name: "main", sourceDirs: [root.appendingPathComponent("src/main/java")])
        let test = JavaGradleProjectModel.SourceSet(
            name: "test", sourceDirs: [testDir],
            compileClasspathJars: [URL(fileURLWithPath: "/m/junit-jupiter-api-5.10.jar")]
        )
        let sub = JavaGradleProjectModel.Subproject(path: ":app", directory: root, sourceSets: [main, test])
        return JavaGradleProjectModel(formatVersion: 6, gradleVersion: "8.5", subprojects: [sub])
    }

    func testTestSourceSetsSelection() {
        let model = makeModel()
        XCTAssertEqual(model.subprojects[0].testSourceSets.map(\.name), ["test"])
        XCTAssertEqual(model.testSourceSetRefs.map(\.subprojectPath), [":app"])
    }

    func testDiscoverBuildsTreeAndSkipsBuildDirs() async throws {
        try write("a/FooTest.java", classSource("FooTest"))
        try write("build/Ignored.java", classSource("Ignored"))
        try write("Helper.java", "class Helper {}")
        let discovery = JavaTestDiscovery(model: makeModel())
        let tree = await discovery.discover()
        XCTAssertEqual(tree.subprojects.map(\.path), [":app"])
        let set = tree.subprojects[0].sourceSets[0]
        XCTAssertEqual(set.name, "test")
        XCTAssertEqual(set.frameworks, [.junit5])
        XCTAssertEqual(set.classes.map(\.testClass.simpleName), ["FooTest"])
        XCTAssertEqual(set.classes[0].fileURL.lastPathComponent, "FooTest.java")
    }

    func testStampCacheHit() async throws {
        try write("FooTest.java", classSource("FooTest"))
        let discovery = JavaTestDiscovery(model: makeModel())
        _ = await discovery.discover()
        let first = await discovery.scanCount
        _ = await discovery.discover()
        let second = await discovery.scanCount
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 1)
    }

    func testUpdateRescansChangedAndAddsNewFiles() async throws {
        let foo = try write("FooTest.java", classSource("FooTest"))
        let discovery = JavaTestDiscovery(model: makeModel())
        _ = await discovery.discover()
        try write("FooTest.java", "import org.junit.jupiter.api.Test;\nclass FooTest { @Test void t() {} @Test void u() {} }")
        let bar = try write("BarTest.java", classSource("BarTest"))
        let tree = await discovery.update(files: [foo, bar])
        let classes = tree.allClasses
        XCTAssertEqual(classes.map(\.testClass.simpleName), ["BarTest", "FooTest"])
        XCTAssertEqual(classes.last?.testClass.methods.count, 2)
    }

    func testRemove() async throws {
        let foo = try write("FooTest.java", classSource("FooTest"))
        try write("BarTest.java", classSource("BarTest"))
        let discovery = JavaTestDiscovery(model: makeModel())
        _ = await discovery.discover()
        let tree = await discovery.remove(files: [foo])
        XCTAssertEqual(tree.allClasses.map(\.testClass.simpleName), ["BarTest"])
        try FileManager.default.removeItem(at: foo)
        let again = await discovery.discover()
        XCTAssertEqual(again.allClasses.map(\.testClass.simpleName), ["BarTest"])
    }

    func testBufferOverride() async throws {
        let foo = try write("FooTest.java", classSource("FooTest"))
        let discovery = JavaTestDiscovery(model: makeModel())
        _ = await discovery.discover()
        await discovery.setBufferText(
            "import org.junit.jupiter.api.Test;\nclass FooTest { @Test void a() {} @Test void b() {} @Test void c() {} }", for: foo)
        var tree = await discovery.update(files: [foo])
        XCTAssertEqual(tree.allClasses[0].testClass.methods.count, 3)
        await discovery.setBufferText(nil, for: foo)
        tree = await discovery.update(files: [foo])
        XCTAssertEqual(tree.allClasses[0].testClass.methods.count, 1)
    }

    func testAbstractClassesExcludedFromTree() async throws {
        try write("BaseTest.java", "import org.junit.jupiter.api.Test;\nabstract class BaseTest { @Test void t() {} }\nclass ImplTest extends BaseTest {}")
        let discovery = JavaTestDiscovery(model: makeModel())
        let tree = await discovery.discover()
        XCTAssertEqual(tree.allClasses.map(\.testClass.simpleName), ["ImplTest"])
    }
}
