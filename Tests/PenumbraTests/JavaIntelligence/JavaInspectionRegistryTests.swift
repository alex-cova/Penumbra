import XCTest
@testable import JavaIntelligence

final class JavaInspectionRegistryTests: XCTestCase {
    private let legacy: Set<JavaInspectionRule> = [
        .unusedImport, .duplicateImport, .unresolvedImport, .missingOverride, .unresolvedType, .classFileNameMismatch,
    ]

    func testEveryRuleHasUniqueCodeAndRoundTrips() {
        var codes = Set<String>()
        for rule in JavaInspectionRule.allCases {
            XCTAssertTrue(codes.insert(rule.code).inserted, "duplicate code \(rule.code)")
            XCTAssertEqual(JavaInspectionRule(code: rule.code), rule)
            XCTAssertFalse(rule.title.isEmpty)
            XCTAssertFalse(rule.summary.isEmpty)
        }
    }

    func testEveryNonLegacyRuleHasExactlyOneRegisteredInspection() {
        for rule in JavaInspectionRule.allCases where !legacy.contains(rule) {
            let matches = JavaInspectionRegistry.nodeInspections.filter { $0.rule == rule }
            XCTAssertEqual(matches.count, 1, "\(rule.code) is registered \(matches.count) times")
        }
        for inspection in JavaInspectionRegistry.nodeInspections {
            XCTAssertFalse(legacy.contains(inspection.rule))
        }
    }

    func testPositionIndexMatchesTheSlowConversion() throws {
        let source = "class A {\n    String s = \"héllo 😀 wörld\";\r\n    int x;\n}\n"
        let tree = try XCTUnwrap(JavaSyntaxParser().parse(source))
        let bytes = tree.sourceBytes
        for offset in 0...bytes.count {
            let fast = JavaInspectionSupport.position(forByte: offset, in: tree)
            let slow = JavaImportInserter.textPosition(forByteOffset: offset, in: bytes)
            // Offsets inside a multi-byte character have no exact UTF-16 position.
            guard offset == bytes.count || bytes[offset] & 0xC0 != 0x80 else { continue }
            XCTAssertEqual(fast.line, slow.line, "line at \(offset)")
            XCTAssertEqual(fast.column, slow.column, "column at \(offset)")
            XCTAssertEqual(fast.utf16Offset, slow.utf16Offset, "offset at \(offset)")
        }
    }
}
