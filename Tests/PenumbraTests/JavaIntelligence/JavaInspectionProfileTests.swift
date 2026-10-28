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

    func testSectionsOtherLanguagesKeepSurviveARoundTripUntouched() throws {
        let json = #"{"disabled":["a"],"name":"Team","severities":{},"swift":{"disabled":["force-unwrap"],"limits":{"long-function":120},"nested":{"flag":true,"ratio":0.5,"list":[1,"two",null]}}}"#
        let profile = try JSONDecoder().decode(JavaInspectionProfile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.name, "Team")
        XCTAssertEqual(Set(profile.sections.keys), ["swift"])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let again = try encoder.encode(profile)
        let reread = try JSONDecoder().decode(JavaInspectionProfile.self, from: again)
        XCTAssertEqual(reread, profile, "the section is carried as written")
        let swift = try JSONSerialization.jsonObject(with: XCTUnwrap(reread.sections["swift"])) as? [String: Any]
        XCTAssertEqual(swift?["disabled"] as? [String], ["force-unwrap"])
        XCTAssertEqual((swift?["limits"] as? [String: Int])?["long-function"], 120)
        XCTAssertEqual((swift?["nested"] as? [String: Any])?["flag"] as? Bool, true)

        // Editing Java's side leaves the other section alone, and a profile without one writes no extra key.
        var edited = reread
        edited.setEnabled(true, for: .selfAssignment)
        XCTAssertEqual(edited.sections, reread.sections)
        let plain = try String(decoding: encoder.encode(JavaInspectionProfile.standard()), as: UTF8.self)
        XCTAssertFalse(plain.contains("swift"))
        XCTAssertEqual(JavaInspectionProfile.standard().sections, [:])
    }
}

