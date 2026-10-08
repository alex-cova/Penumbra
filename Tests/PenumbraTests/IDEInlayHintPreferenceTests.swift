import XCTest
import JavaIntelligence
@testable import Umbra

/// Each kind of Java inlay hint has its own setting, and the provider reads them as they are now.
@MainActor
final class IDEInlayHintPreferenceTests: XCTestCase {
    private var original: (Bool, Bool, Bool)?
    private var originalCodeVision: (Bool, Bool)?

    override func setUp() {
        super.setUp()
        let preferences = IDEPreferences.shared
        original = (preferences.javaInlayHints, preferences.javaInlayVariableTypes, preferences.javaInlayLambdaTypes)
        originalCodeVision = (preferences.javaCodeVisionUsages, preferences.javaCodeVisionImplementations)
    }

    override func tearDown() {
        if let original {
            let preferences = IDEPreferences.shared
            preferences.javaInlayHints = original.0
            preferences.javaInlayVariableTypes = original.1
            preferences.javaInlayLambdaTypes = original.2
        }
        if let originalCodeVision {
            let preferences = IDEPreferences.shared
            preferences.javaCodeVisionUsages = originalCodeVision.0
            preferences.javaCodeVisionImplementations = originalCodeVision.1
        }
        super.tearDown()
    }

    func testHintsAreRequestedWhenAnyKindIsOn() {
        let preferences = IDEPreferences.shared
        preferences.javaInlayHints = false
        preferences.javaInlayVariableTypes = false
        preferences.javaInlayLambdaTypes = false
        XCTAssertFalse(preferences.areInlayHintsEnabled)

        preferences.javaInlayVariableTypes = true
        XCTAssertTrue(preferences.areInlayHintsEnabled)
        preferences.javaInlayVariableTypes = false
        preferences.javaInlayLambdaTypes = true
        XCTAssertTrue(preferences.areInlayHintsEnabled)
    }

    func testProviderOptionsFollowTheSettingsAtCallTime() {
        let preferences = IDEPreferences.shared
        preferences.javaInlayHints = true
        preferences.javaInlayVariableTypes = true
        preferences.javaInlayLambdaTypes = false
        XCTAssertEqual(
            IDEPreferences.currentJavaInlayHintOptions(),
            JavaInlayHintOptions(parameterNames: true, variableTypes: true, lambdaParameterTypes: false)
        )

        preferences.javaInlayHints = false
        preferences.javaInlayLambdaTypes = true
        XCTAssertEqual(
            IDEPreferences.currentJavaInlayHintOptions(),
            JavaInlayHintOptions(parameterNames: false, variableTypes: true, lambdaParameterTypes: true)
        )
    }

    func testCodeVisionLabelsHaveTheirOwnSettings() {
        let preferences = IDEPreferences.shared
        preferences.javaCodeVisionUsages = false
        preferences.javaCodeVisionImplementations = false
        XCTAssertFalse(preferences.areCodeVisionLensesEnabled)

        preferences.javaCodeVisionImplementations = true
        XCTAssertTrue(preferences.areCodeVisionLensesEnabled)
        XCTAssertEqual(IDEPreferences.currentJavaCodeVisionOptions(), JavaCodeVisionOptions(usages: false, implementations: true))

        preferences.javaCodeVisionUsages = true
        XCTAssertEqual(IDEPreferences.currentJavaCodeVisionOptions(), JavaCodeVisionOptions(usages: true, implementations: true))
    }
}
