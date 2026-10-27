import Foundation
import SwiftIntelligence
import XCTest
@testable import Umbra

/// Settings ▸ Swift ▸ Inspections stores rule codes, and only what differs from each rule's default.
@MainActor
final class IDESwiftInspectionSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        super.setUp()
        suite = "IDESwiftInspectionSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testNothingStoredMeansEveryRuleIsAtItsDefault() {
        let options = IDESwiftInspectionSettings.current(defaults: defaults)
        XCTAssertEqual(options, SwiftInspectionOptions())
        XCTAssertEqual(options.enabledRules, Set(SwiftInspectionRule.allCases.filter(\.isEnabledByDefault)))
    }

    func testSwitchingARuleAgainstItsDefaultStoresOnlyThatCode() throws {
        let model = IDESwiftInspectionModel(defaults: defaults)
        let onByDefault = try XCTUnwrap(SwiftInspectionRule.allCases.first(where: \.isEnabledByDefault))
        model.setEnabled(false, for: onByDefault)
        XCTAssertEqual(defaults.stringArray(forKey: IDESwiftInspectionSettings.disabledKey), [onByDefault.code])
        XCTAssertEqual(defaults.stringArray(forKey: IDESwiftInspectionSettings.enabledKey) ?? [], [])
        XCTAssertFalse(IDESwiftInspectionSettings.current(defaults: defaults).isEnabled(onByDefault))

        // Back to the default: nothing is stored for it any more.
        model.setEnabled(true, for: onByDefault)
        XCTAssertEqual(defaults.stringArray(forKey: IDESwiftInspectionSettings.disabledKey) ?? [], [])
        XCTAssertEqual(IDESwiftInspectionSettings.current(defaults: defaults), SwiftInspectionOptions())
    }

    func testARuleOffByDefaultCanBeSwitchedOn() throws {
        guard let offByDefault = SwiftInspectionRule.allCases.first(where: { !$0.isEnabledByDefault }) else {
            return // every rule ships on; nothing to switch
        }
        let model = IDESwiftInspectionModel(defaults: defaults)
        model.setEnabled(true, for: offByDefault)
        XCTAssertEqual(defaults.stringArray(forKey: IDESwiftInspectionSettings.enabledKey), [offByDefault.code])
        XCTAssertTrue(IDESwiftInspectionSettings.current(defaults: defaults).isEnabled(offByDefault))
    }

    func testSeverityIsStoredOnlyWhenItDiffersFromTheDefault() {
        let model = IDESwiftInspectionModel(defaults: defaults)
        let rule = SwiftInspectionRule.forceUnwrap
        let other = SwiftInspection.Severity.allCases.first { $0 != rule.defaultSeverity }!
        model.setSeverity(other, for: rule)
        XCTAssertEqual(IDESwiftInspectionSettings.current(defaults: defaults).severity(of: rule), other)
        model.setSeverity(rule.defaultSeverity, for: rule)
        XCTAssertTrue(IDESwiftInspectionSettings.current(defaults: defaults).severities.isEmpty)
    }

    func testLimitsRoundTripAndDefaultsAreNotStored() {
        let model = IDESwiftInspectionModel(defaults: defaults)
        model.setLimit(120, for: .longFunction)
        model.setLimit(9, for: .highComplexity)
        model.setLimit(3, for: .manyParameters)
        var options = IDESwiftInspectionSettings.current(defaults: defaults)
        XCTAssertEqual(options.limits.functionLines, 120)
        XCTAssertEqual(options.limits.complexity, 9)
        XCTAssertEqual(options.limits.parameters, 3)

        model.setLimit(SwiftInspectionLimits.standard.functionLines, for: .longFunction)
        let stored = defaults.dictionary(forKey: IDESwiftInspectionSettings.limitsKey) as? [String: Int]
        XCTAssertNil(stored?[SwiftInspectionRule.longFunction.code])

        // A rule without a threshold ignores the call.
        model.setLimit(1, for: .forceUnwrap)
        options = IDESwiftInspectionSettings.current(defaults: defaults)
        XCTAssertEqual(options.limits.complexity, 9)
    }

    func testRestoreDefaultsClearsEverything() {
        let model = IDESwiftInspectionModel(defaults: defaults)
        model.setEnabled(false, for: .forceUnwrap)
        model.setLimit(77, for: .longFunction)
        model.resetToDefaults()
        XCTAssertEqual(IDESwiftInspectionSettings.current(defaults: defaults), SwiftInspectionOptions())
    }

    func testOnlyMetricRulesOfferALimit() {
        let options = SwiftInspectionOptions()
        for rule in SwiftInspectionRule.allCases {
            let isMetric = [SwiftInspectionRule.longFunction, .highComplexity, .manyParameters].contains(rule)
            XCTAssertEqual(IDESwiftInspectionSettings.limit(of: rule, in: options) != nil, isMetric, rule.code)
        }
    }

    func testSupportAnswersWithTheInspectionsFromSettings() async {
        let support = IDESwiftSupport()
        // `current()` reads the standard defaults, so only the wiring is asserted here, not a rule's state.
        let analysis = support.inspections.analysis(of: "let x = y!\n")
        XCTAssertEqual(analysis.findings.contains { $0.id == SwiftInspectionRule.forceUnwrap.code },
                       IDESwiftInspectionSettings.current().isEnabled(.forceUnwrap))
    }
}
