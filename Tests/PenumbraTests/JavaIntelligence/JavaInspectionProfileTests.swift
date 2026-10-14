import XCTest
@testable import JavaIntelligence

final class JavaInspectionProfileTests: XCTestCase {
    private let main = JavaInspectionFileContext(relativePath: "app/src/main/java/a/Foo.java", isTest: false)
    private let test = JavaInspectionFileContext(relativePath: "app/src/test/java/a/FooTest.java", isTest: true)

    func testStandardProfileMatchesTheRuleDefaults() {
        let profile = JavaInspectionProfile.standard()
        XCTAssertEqual(profile.enabledRules(), JavaInspectionRule.enabledByDefault)
        for rule in JavaInspectionRule.allCases {
            XCTAssertEqual(profile.resolution(of: rule).severity, rule.defaultSeverity)
            XCTAssertFalse(profile.resolution(of: rule).isSeverityExplicit)
        }
    }

    func testEmptyProfileSwitchesEverythingOff() {
        XCTAssertTrue(JavaInspectionProfile.empty(name: "Mine").enabledRules().isEmpty)
    }

    func testSeverityIsStoredOnlyWhenItDiffersFromTheDefault() {
        var profile = JavaInspectionProfile.standard()
        let rule = JavaInspectionRule.stringComparisonIdentity
        profile.setSeverity(.error, for: rule)
        XCTAssertEqual(profile.severities[rule.code], "error")
        XCTAssertTrue(profile.resolution(of: rule).isSeverityExplicit)
        profile.setSeverity(rule.defaultSeverity, for: rule)
        XCTAssertNil(profile.severities[rule.code])
    }

    func testTestScopeOverridesTheBaseChoiceOnlyInTests() {
        var profile = JavaInspectionProfile.standard()
        let rule = JavaInspectionRule.systemOutErr
        profile.scopedOverrides = [.init(code: rule.code, scope: .tests, isEnabled: false)]
        XCTAssertTrue(profile.isEnabled(rule, in: main))
        XCTAssertFalse(profile.isEnabled(rule, in: test))
        XCTAssertFalse(profile.enabledRules(in: test).contains(rule))
        XCTAssertTrue(profile.enabledRules(in: main).contains(rule))
    }

    func testFirstMatchingScopeWins() {
        var profile = JavaInspectionProfile.standard()
        let rule = JavaInspectionRule.printStackTraceCall
        profile.scopedOverrides = [
            .init(code: rule.code, scope: .glob("**/generated/**"), severity: "noHighlighting"),
            .init(code: rule.code, scope: .tests, severity: "error"),
        ]
        let generated = JavaInspectionFileContext(relativePath: "build/generated/x/A.java", isTest: true)
        XCTAssertEqual(profile.resolution(of: rule, in: generated).severity, .noHighlighting)
        XCTAssertEqual(profile.resolution(of: rule, in: test).severity, .error)
        XCTAssertEqual(profile.resolution(of: rule, in: main).severity, rule.defaultSeverity)
    }

    func testRoundTripKeepsCodesThisBuildDoesNotKnow() throws {
        var profile = JavaInspectionProfile.standard(name: "Shared")
        profile.disabled.insert("some-future-rule")
        profile.severities["some-future-rule"] = "warning"
        profile.scopedOverrides = [.init(code: "some-future-rule", scope: .glob("*Dto.java"), isEnabled: true)]
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(JavaInspectionProfile.self, from: data)
        XCTAssertEqual(decoded, profile)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("glob:*Dto.java"))
    }

    func testMissingKeysDecodeToDefaults() throws {
        let decoded = try JSONDecoder().decode(JavaInspectionProfile.self, from: Data(#"{"name":"X"}"#.utf8))
        XCTAssertEqual(decoded.name, "X")
        XCTAssertEqual(decoded.disabled, JavaInspectionProfile.defaultDisabledCodes)
        XCTAssertTrue(decoded.treatsPublicApiAsUsed)
    }

    func testClassifierFindsTestsAndRelativePaths() {
        let classifier = JavaInspectionFileClassifier(
            projectRoot: URL(fileURLWithPath: "/work/proj"),
            testRoots: [URL(fileURLWithPath: "/work/proj/it/java")]
        )
        let inTestRoot = classifier.context(for: URL(fileURLWithPath: "/work/proj/it/java/a/B.java"))
        XCTAssertTrue(inTestRoot.isTest)
        XCTAssertEqual(inTestRoot.relativePath, "it/java/a/B.java")
        XCTAssertTrue(classifier.context(for: URL(fileURLWithPath: "/work/proj/m/src/test/java/C.java")).isTest)
        XCTAssertFalse(classifier.context(for: URL(fileURLWithPath: "/work/proj/m/src/main/java/C.java")).isTest)
    }

    func testGlobSemantics() {
        XCTAssertTrue(JavaPathGlob.matches(pattern: "*Test.java", path: "a/b/FooTest.java"))
        XCTAssertFalse(JavaPathGlob.matches(pattern: "a/*.java", path: "a/b/Foo.java"))
        XCTAssertTrue(JavaPathGlob.matches(pattern: "a/**/*.java", path: "a/b/c/Foo.java"))
        XCTAssertTrue(JavaPathGlob.matches(pattern: "**/generated/**", path: "x/generated/y/Foo.java"))
        XCTAssertTrue(JavaPathGlob.matches(pattern: "**/generated/**", path: "generated/Foo.java"))
        XCTAssertTrue(JavaPathGlob.passes(masks: "*.java, !**/generated/**", path: "src/Foo.java"))
        XCTAssertFalse(JavaPathGlob.passes(masks: "*.java, !**/generated/**", path: "src/generated/Foo.java"))
        XCTAssertTrue(JavaPathGlob.passes(masks: "", path: "anything"))
        XCTAssertTrue(JavaPathGlob.passes(masks: "!**/generated/**", path: "src/Foo.java"))
    }
}
