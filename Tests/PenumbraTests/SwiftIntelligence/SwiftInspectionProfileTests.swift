import EditorIntelligence
import Foundation
import SwiftIntelligence
import XCTest

/// Swift inspection profiles: deviations from the defaults, scopes per file, the file format, "No highlighting", and the
/// service and batch run asking for options per file.
final class SwiftInspectionProfileTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/proj")
    private var classifier: SwiftInspectionFileClassifier { SwiftInspectionFileClassifier(projectRoot: root) }

    private func file(_ relative: String) -> SwiftInspectionFileContext {
        classifier.context(for: root.appendingPathComponent(relative))
    }

    func testTheStandardProfileMakesTheRulesOwnChoices() {
        XCTAssertEqual(SwiftInspectionProfile.standard.options(), SwiftInspectionOptions())
        XCTAssertEqual(SwiftInspectionProfile.standard.options(for: file("Sources/A.swift")), SwiftInspectionOptions())
        XCTAssertEqual(SwiftInspectionProfile.standard.sectionData, SwiftInspectionProfile().sectionData)
    }

    func testOnlyDeviationsAreStored() {
        var profile = SwiftInspectionProfile.standard
        profile.setEnabled(false, for: .emptyCatch)
        profile.setEnabled(true, for: .forceUnwrap)
        XCTAssertEqual(profile.disabled, ["empty-catch"])
        XCTAssertEqual(profile.enabled, ["force-unwrap"])
        profile.setEnabled(true, for: .emptyCatch)
        profile.setEnabled(false, for: .forceUnwrap)
        XCTAssertEqual(profile, .standard, "back to the defaults leaves nothing behind")

        profile.setSeverity(.error, for: .forceUnwrap)
        XCTAssertEqual(profile.severities, ["force-unwrap": "error"])
        profile.setSeverity(SwiftInspectionRule.forceUnwrap.defaultSeverity, for: .forceUnwrap)
        XCTAssertTrue(profile.severities.isEmpty)

        profile.setLimit(5_000, for: .longFunction)
        XCTAssertEqual(profile.limits[SwiftInspectionRule.longFunction.code], 1_000, "clamped to the range")
        profile.setLimit(SwiftInspectionRule.longFunction.limit!.defaultValue, for: .longFunction)
        XCTAssertTrue(profile.limits.isEmpty)
        profile.setLimit(3, for: .forceUnwrap)
        XCTAssertTrue(profile.limits.isEmpty, "a rule without a threshold ignores the call")
    }

    func testAScopeChangesOnlyTheFilesItMatches() {
        var profile = SwiftInspectionProfile.standard
        profile.setEnabled(true, for: .forceUnwrap)
        profile.scopedOverrides = [
            .init(code: "force-unwrap", scope: .tests, isEnabled: false),
            .init(code: "empty-catch", scope: .glob("**/Generated/**"), isEnabled: false),
            .init(code: "redundant-return", scope: .glob("Sources/Legacy/**"), severity: "error"),
        ]
        let source = file("Sources/App/A.swift")
        let test = file("Tests/AppTests/ATests.swift")
        XCTAssertTrue(test.isTest)
        XCTAssertFalse(source.isTest)

        XCTAssertTrue(profile.isEnabled(.forceUnwrap, in: source))
        XCTAssertFalse(profile.isEnabled(.forceUnwrap, in: test))
        XCTAssertTrue(profile.options(for: source).isEnabled(.forceUnwrap))
        XCTAssertFalse(profile.options(for: test).isEnabled(.forceUnwrap))

        XCTAssertFalse(profile.options(for: file("Sources/App/Generated/Model.swift")).isEnabled(.emptyCatch))
        XCTAssertTrue(profile.options(for: source).isEnabled(.emptyCatch))

        XCTAssertEqual(profile.options(for: file("Sources/Legacy/Old.swift")).severity(of: .redundantReturn), .error)
        XCTAssertEqual(profile.options(for: source).severity(of: .redundantReturn), SwiftInspectionRule.redundantReturn.defaultSeverity)
        // Without a file the base choices apply.
        XCTAssertTrue(profile.options().isEnabled(.forceUnwrap))
    }

    func testTheFirstMatchingScopeOfARuleWins() {
        var profile = SwiftInspectionProfile.standard
        profile.scopedOverrides = [
            .init(code: "empty-catch", scope: .tests, isEnabled: false),
            .init(code: "empty-catch", scope: .glob("Tests/**"), isEnabled: true),
        ]
        XCTAssertFalse(profile.isEnabled(.emptyCatch, in: file("Tests/AppTests/ATests.swift")))
    }

    func testTheFileFormatRoundTripsAndKeepsWhatItDoesNotKnow() throws {
        var profile = SwiftInspectionProfile.standard
        profile.setEnabled(false, for: .emptyCatch)
        profile.setSeverity(.noHighlighting, for: .redundantReturn)
        profile.setLimit(120, for: .longFunction)
        profile.scopedOverrides = [.init(code: "force-unwrap", scope: .tests, isEnabled: false), .init(code: "x", scope: .glob("a/**"), severity: "warning")]
        XCTAssertEqual(SwiftInspectionProfile(sectionData: profile.sectionData), profile)
        XCTAssertEqual(profile.sectionData, SwiftInspectionProfile(sectionData: profile.sectionData)?.sectionData, "byte-identical, so an unchanged profile is not a change")

        // A code this build does not know, and a file with sections missing.
        let future = #"{"disabled":["not-a-rule-yet"],"severities":{"also-new":"warning"}}"#
        let decoded = try XCTUnwrap(SwiftInspectionProfile(sectionData: Data(future.utf8)))
        XCTAssertEqual(decoded.disabled, ["not-a-rule-yet"])
        XCTAssertEqual(decoded.options().enabledRules, SwiftInspectionOptions().enabledRules, "an unknown code switches nothing off")
        XCTAssertEqual(SwiftInspectionProfile(sectionData: Data("{}".utf8)), .standard)
        XCTAssertNil(SwiftInspectionProfile(sectionData: Data("[1]".utf8)))
        XCTAssertNil(SwiftInspectionProfile(sectionData: nil))
        XCTAssertThrowsError(try JSONDecoder().decode(SwiftInspectionProfile.Scope.self, from: Data(#""folder""#.utf8)))
    }

    func testAProfileCanBeMadeFromTheFlatOptionsTheSettingsHadBefore() {
        var options = SwiftInspectionOptions()
        options.disabled = ["empty-catch"]
        options.enabled = ["force-try"]
        options.severities = ["force-try": .error]
        options.limits = SwiftInspectionLimits(functionLines: 120, complexity: 15, parameters: 6)
        let profile = SwiftInspectionProfile(options: options)
        XCTAssertEqual(profile.options(), options)
        XCTAssertEqual(profile.limits, ["long-function": 120])
    }

    func testEmptyTurnsEveryRuleOffAndIsModifiedSeesDeviations() {
        let empty = SwiftInspectionProfile.empty
        XCTAssertTrue(SwiftInspectionRule.allCases.allSatisfy { !empty.isEnabled($0) })
        var profile = SwiftInspectionProfile.standard
        XCTAssertFalse(SwiftInspectionRule.allCases.contains { profile.isModified($0) })
        profile.setEnabled(false, for: .emptyCatch)
        XCTAssertTrue(profile.isModified(.emptyCatch))
        XCTAssertFalse(profile.isModified(.explicitInit))
    }

    // MARK: - No highlighting

    private func document(_ text: String) -> Document {
        let origin = TextPosition(line: 0, column: 0, utf16Offset: 0)
        return Document(
            url: URL(fileURLWithPath: "/proj/Sources/A.swift"), displayName: "A.swift",
            contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: EditorIntelligence.TextRange(start: origin, end: origin)),
            cursor: Cursor(position: origin), viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: "swift"
        )
    }

    func testNoHighlightingDrawsNothingButKeepsTheFixAndTheRunReportsIt() async throws {
        var chosen = SwiftInspectionOptions()
        chosen.severities = ["redundant-void-return": .noHighlighting]
        let options = chosen
        let service = SwiftInspectionService(options: { options })
        let text = "func a() -> Void { }\n"
        let doc = document(text)

        let diagnostics = await SwiftInspectionDiagnosticProvider(service: service).diagnostics(for: doc)
        XCTAssertTrue(diagnostics.isEmpty, "nothing is drawn")
        let actions = await SwiftCodeActionProvider(inspections: service).codeActions(
            for: doc, at: TextPosition(line: 0, column: 12, utf16Offset: 12), diagnostics: []
        )
        XCTAssertTrue(actions.contains { $0.title == "Remove return type" }, "the fix stays on ⌥↩")
        XCTAssertFalse(actions.contains { $0.title.hasPrefix("Turn off highlighting") }, "it is already off")

        let found = SwiftBatchInspector.located(in: text, options: .init(inspection: options))
        XCTAssertEqual(found.first?.inspection.severity, .noHighlighting, "Inspect Code still lists it")

        // A drawn one offers to turn the highlighting off.
        let loud = await SwiftCodeActionProvider(inspections: SwiftInspectionService()).codeActions(
            for: doc, at: TextPosition(line: 0, column: 12, utf16Offset: 12), diagnostics: []
        )
        let quiet = try XCTUnwrap(loud.first { $0.title.hasPrefix("Turn off highlighting") })
        XCTAssertEqual(quiet.command, CodeActionCommand(id: SwiftInspectionCommand.quiet, arguments: ["redundant-void-return"]))
    }

    // MARK: - Per file

    func testTheServiceAsksForOptionsOfTheFileItAnalyses() async {
        let profile: SwiftInspectionProfile = {
            var profile = SwiftInspectionProfile.standard
            profile.scopedOverrides = [.init(code: "redundant-void-return", scope: .tests, isEnabled: false)]
            return profile
        }()
        let classifier = SwiftInspectionFileClassifier(projectRoot: URL(fileURLWithPath: "/proj"))
        let service = SwiftInspectionService(optionsForFile: { url in profile.options(for: url.map(classifier.context(for:))) })
        let text = "func a() -> Void { }\n"
        func document(at path: String) -> Document {
            let origin = TextPosition(line: 0, column: 0, utf16Offset: 0)
            return Document(
                url: URL(fileURLWithPath: path), displayName: "x.swift", contentSnapshot: TextSnapshot(version: 0, text: text),
                selection: Selection(range: EditorIntelligence.TextRange(start: origin, end: origin)),
                cursor: Cursor(position: origin), viewport: Viewport(x: 0, y: 0, width: 100, height: 100), languageIdentifier: "swift"
            )
        }
        let provider = SwiftInspectionDiagnosticProvider(service: service)
        let inSources = await provider.diagnostics(for: document(at: "/proj/Sources/App/A.swift"))
        let inTests = await provider.diagnostics(for: document(at: "/proj/Tests/AppTests/ATests.swift"))
        XCTAssertEqual(inSources.count, 1)
        XCTAssertTrue(inTests.isEmpty, "the tests scope switched the rule off for that file")
    }

    func testABatchRunResolvesOptionsPerFile() {
        let text = "func a() -> Void { }\n"
        var options = SwiftBatchInspector.Options(inspection: SwiftInspectionOptions())
        options.optionsForFile = { url in
            var chosen = SwiftInspectionOptions()
            if url.lastPathComponent == "Quiet.swift" { chosen.disabled = ["redundant-void-return"] }
            return chosen
        }
        XCTAssertEqual(SwiftBatchInspector.located(in: text, effectiveOptions: options.effective(for: URL(fileURLWithPath: "/p/Loud.swift"))).count, 1)
        XCTAssertEqual(SwiftBatchInspector.located(in: text, effectiveOptions: options.effective(for: URL(fileURLWithPath: "/p/Quiet.swift"))).count, 0)
        options.onlyRules = [.redundantVoidReturn]
        XCTAssertEqual(SwiftBatchInspector.located(in: text, effectiveOptions: options.effective(for: URL(fileURLWithPath: "/p/Quiet.swift"))).count, 1, "a run by name ignores the profile's switches")
    }
}
