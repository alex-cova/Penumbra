import XCTest
import JavaIntelligence
@testable import Umbra

/// Each kind of Java inlay hint has its own setting, and the provider reads them as they are now.
@MainActor
final class IDEInlayHintPreferenceTests: XCTestCase {
    private var original: (Bool, Bool, Bool)?

    override func setUp() {
        super.setUp()
        let preferences = IDEPreferences.shared
        original = (preferences.javaInlayHints, preferences.javaInlayVariableTypes, preferences.javaInlayLambdaTypes)
    }

    override func tearDown() {
        if let original {
            let preferences = IDEPreferences.shared
            preferences.javaInlayHints = original.0
            preferences.javaInlayVariableTypes = original.1
            preferences.javaInlayLambdaTypes = original.2
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
}
