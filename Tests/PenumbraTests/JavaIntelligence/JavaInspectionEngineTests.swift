import EditorIntelligence
import XCTest
@testable import JavaIntelligence

final class JavaInspectionEngineTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("java-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testDuplicateImportInspectionFlagsSecondImport() {
        let source = """
        import java.util.List;
        import java.util.List;

        class T { List<String> names; }
        """
        let tree = try XCTUnwrap(JavaSyntaxParser().parse(source))
        let inspections = JavaDuplicateImportInspection.inspect(source: source, tree: tree)
        XCTAssertEqual(inspections.map(\.id), ["duplicate-import"])
    }

    func testClassFileNameMismatchFlagsPublicTypeName() {
        let url = scratch.appendingPathComponent("Wrong.java")
        let source = "public class Right { }"
        let tree = try XCTUnwrap(JavaSyntaxParser().parse(source))
        let context = try XCTUnwrap(JavaInspectionContext(source: source, tree: tree, url: url, index: JavaIndex()))
        let inspections = JavaClassFileNameInspection.inspect(context: context)
        XCTAssertEqual(inspections.first?.id, "class-file-name-mismatch")
    }
}
