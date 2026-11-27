import Foundation
import JavaIntelligence
import XCTest

final class JavaVersionDeclarationTests: XCTestCase {
    func testSDKMANUsesUTF16LineOffsetsAndMatchesVendor() throws {
        let source = "# ☕️ Java\r\njava=25-tem # project SDK\n"
        let declarations = JavaVersionDeclaration.parse(fileName: ".sdkmanrc", source: source)
        let declaration = try XCTUnwrap(declarations.first)
        XCTAssertEqual(declarations.count, 1)
        XCTAssertEqual(declaration.utf16Offset, (source as NSString).range(of: "java=").location)
        let requirement = try XCTUnwrap(declaration.requirement)
        let home = URL(fileURLWithPath: "/jdk")
        XCTAssertTrue(requirement.matches(.init(home: home, featureVersion: 25, versionString: "25.0.1", vendor: "Eclipse Adoptium")))
        XCTAssertFalse(requirement.matches(.init(home: home, featureVersion: 25, versionString: "25.0.1", vendor: "Amazon.com Inc.")))
        XCTAssertFalse(requirement.matches(.init(home: home, featureVersion: 26, versionString: "26", vendor: "Eclipse Adoptium")))
    }

    func testASDFRejectsFallbackAndExecutableValues() throws {
        let fileName = ".tool-versions"
        let declarations = JavaVersionDeclaration.parse(
            fileName: fileName, source: "nodejs 24\njava temurin-24.0.2+12\njava system temurin-25\njava path:/tmp/fake"
        )
        XCTAssertEqual(declarations.count, 3)
        XCTAssertEqual(declarations[0].requirement?.featureVersion, 24)
        XCTAssertNil(declarations[1].requirement)
        XCTAssertNil(declarations[2].requirement)
    }

    func testJavaVersionAcceptsLiteralFeatureVersion() {
        let result = JavaVersionDeclaration.parse(fileName: ".java-version", source: "21\n")
        XCTAssertEqual(result.first?.requirement?.featureVersion, 21)
        XCTAssertEqual(result.first?.utf16Offset, 0)
    }
}
