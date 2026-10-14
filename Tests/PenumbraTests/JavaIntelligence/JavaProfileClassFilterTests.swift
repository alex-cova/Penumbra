import JavaIntelligence
import XCTest

final class JavaClassPatternTests: XCTestCase {
    private func matches(_ pattern: String, _ className: String) -> Bool {
        JavaClassPattern(pattern)?.matches(className: className) ?? false
    }

    func testAPlainNameIsAClassItsNestedClassesOrAPackage() {
        XCTAssertTrue(matches("com.acme.Util", "com.acme.Util"))
        XCTAssertTrue(matches("com.acme.Util", "com.acme.Util$Helper"))
        XCTAssertTrue(matches("com.acme", "com.acme.Util"))
        XCTAssertTrue(matches("com.acme", "com.acme.sub.Util"))
        XCTAssertFalse(matches("com.acme.Util", "com.acme.UtilityBelt"), "a prefix of the name is not the name")
        XCTAssertFalse(matches("com.acme", "com.acmeinc.Util"), "a package is not a string prefix")
        XCTAssertFalse(matches("Util", "com.acme.Util"), "a plain name is the full name; use *.Util")
    }

    func testWildcardsAnchorTheFirstAndLastPart() {
        XCTAssertTrue(matches("*Proxy", "com.acme.OrderProxy"))
        XCTAssertFalse(matches("*Proxy", "com.acme.ProxyFactory"))
        XCTAssertTrue(matches("com.acme.*", "com.acme.Util"))
        XCTAssertFalse(matches("com.acme.*", "org.com.acme.Util"))
        XCTAssertTrue(matches("*.internal.*", "org.lib.internal.Thing"))
        XCTAssertFalse(matches("*.internal.*", "org.lib.Thing"))
        XCTAssertTrue(matches("org.*.Thing", "org.lib.Thing"))
        XCTAssertFalse(matches("org.*.Thing", "org.lib.Other"))
        XCTAssertTrue(matches("*Proxy*", "a.ProxyFactory"))
    }

    func testEmptyAndStarOnlyPatternsAreNotPatterns() {
        XCTAssertNil(JavaClassPattern(""))
        XCTAssertNil(JavaClassPattern("  "))
        XCTAssertNil(JavaClassPattern("*"), "would hide everything")
        XCTAssertFalse(matches("com.acme", ""), "a marker frame has no class and is never hidden")
    }

    func testAListIsSplitOnCommasAndSpaces() {
        let list = JavaClassPattern.list(from: "org.springframework, *Proxy  com.acme.Util;")
        XCTAssertEqual(list.map(\.text), ["org.springframework", "*Proxy", "com.acme.Util"])
    }
}

final class JavaProfileComparisonCompatibilityTests: XCTestCase {
    private func profile(
        period: Int?, samples: Int = 40, thread: String = "main", allocations: Int = 0
    ) -> JavaProfile {
        let symbols = JavaProfileSymbols()
        let frame = symbols.internFrame(method: symbols.internMethod(className: "app.Main", name: "run", parameters: ""), line: 1)
        var profile = JavaProfile(symbols: symbols)
        for index in 0..<samples {
            profile.ingest(JFRTextEvent(
                type: "jdk.ExecutionSample", thread: thread, frames: [frame],
                timeMillis: period.map { 1_000 + Int64(index * $0) }
            ))
        }
        for index in 0..<allocations {
            profile.ingest(JFRTextEvent(
                type: "jdk.ObjectAllocationSample", thread: thread, frames: [frame],
                attributes: ["weight": "1 kB", "objectClass": "byte[]"], timeMillis: 1_000 + Int64(index)
            ))
        }
        return profile
    }

    func testSameSettingsAreCompatible() {
        let result = JavaProfileComparison.compatibility(
            baseline: profile(period: 10), target: profile(period: 10), kind: .cpu, thread: nil
        )
        XCTAssertEqual(result, .compatible)
    }

    func testDifferentSamplePeriodsWarnAndSayWhatStillHolds() {
        let result = JavaProfileComparison.compatibility(
            baseline: profile(period: 20), target: profile(period: 10), kind: .cpu, thread: nil
        )
        guard case .warning(let text) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(text.contains("20 ms") && text.contains("10 ms"), text)
        XCTAssertTrue(text.contains("Shares are comparable"), text)
        XCTAssertFalse(result.isIncompatible)

        let absolute = JavaProfileComparison.compatibility(
            baseline: profile(period: 20), target: profile(period: 10), kind: .cpu, thread: nil, basis: .absolute
        )
        XCTAssertTrue(absolute.message?.contains("switch to shares") ?? false, absolute.message ?? "")
    }

    func testPeriodsWithinAMillisecondOrTwoAreTheSame() {
        let result = JavaProfileComparison.compatibility(
            baseline: profile(period: 10), target: profile(period: 12), kind: .cpu, thread: nil
        )
        XCTAssertEqual(result, .compatible)
    }

    func testAKindWithoutSamplesOnEitherSideIsRejected() {
        let baseline = profile(period: 10)
        let withAllocations = profile(period: 10, allocations: 5)
        let missingInBaseline = JavaProfileComparison.compatibility(
            baseline: baseline, target: withAllocations, kind: .allocation, thread: nil
        )
        XCTAssertTrue(missingInBaseline.isIncompatible)
        XCTAssertTrue(missingInBaseline.message?.contains("baseline has no allocation samples") ?? false, missingInBaseline.message ?? "")
        let missingInTarget = JavaProfileComparison.compatibility(
            baseline: withAllocations, target: baseline, kind: .allocation, thread: nil
        )
        XCTAssertTrue(missingInTarget.isIncompatible)
        XCTAssertTrue(missingInTarget.message?.contains("This recording") ?? false, missingInTarget.message ?? "")
        XCTAssertEqual(
            JavaProfileComparison.compatibility(baseline: withAllocations, target: withAllocations, kind: .allocation, thread: nil),
            .compatible
        )
    }

    func testAThreadTheBaselineLacksIsRejected() {
        let result = JavaProfileComparison.compatibility(
            baseline: profile(period: 10, thread: "main"), target: profile(period: 10, thread: "worker"),
            kind: .cpu, thread: "worker"
        )
        XCTAssertTrue(result.isIncompatible)
        XCTAssertTrue(result.message?.contains("\"worker\"") ?? false, result.message ?? "")
    }

    func testTooFewSamplesToEstimateAPeriodSaysNothing() {
        let result = JavaProfileComparison.compatibility(
            baseline: profile(period: 20, samples: 4), target: profile(period: 10), kind: .cpu, thread: nil
        )
        XCTAssertEqual(result, .compatible)
    }
}
