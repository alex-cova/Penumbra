import Penumbra
import XCTest
@testable import Umbra

/// Settings ▸ Markdown (`IDEMarkdownPreviewSettings`): what it hands the preview, how it is stored,
/// and that it travels with the preferences snapshot without breaking older files.
@MainActor
final class IDEMarkdownPreviewSettingsTests: XCTestCase {
    func testDefaultsLeaveThePreviewAsItWas() {
        XCTAssertEqual(IDEMarkdownPreviewSettings().options, MarkdownPreviewOptions())
    }

    func testSettingsBecomeThePreviewOptions() {
        var settings = IDEMarkdownPreviewSettings()
        settings.typeface = .serif
        settings.followsEditorFontSize = false
        settings.fontSize = 17
        settings.lineSpacing = .relaxed
        settings.limitsLineLength = true
        settings.lineLength = 72
        settings.headingAlignment = .center
        settings.numbersHeadings = true
        settings.indentsParagraphs = true
        settings.justifiesParagraphs = true
        settings.tableDensity = .compact
        settings.opensDiagramsOnClick = false
        XCTAssertEqual(settings.options, MarkdownPreviewOptions(
            typeface: .serif, fontSize: 17, lineSpacing: .relaxed, maxLineLength: 72,
            headingAlignment: .center, numbersHeadings: true, indentsParagraphs: true,
            justifiesParagraphs: true, tableDensity: .compact, opensDiagramsOnClick: false
        ))

        // The stored size and length stay, but only count when switched on.
        settings.followsEditorFontSize = true
        settings.limitsLineLength = false
        XCTAssertNil(settings.options.fontSize)
        XCTAssertNil(settings.options.maxLineLength)
    }

    func testOtherTypefaceWithoutAFamilyIsTheEditorFont() {
        var settings = IDEMarkdownPreviewSettings()
        settings.typeface = .custom
        XCTAssertEqual(settings.options.typeface, .editor)
        settings.customFontFamily = "Georgia"
        XCTAssertEqual(settings.options.typeface, .custom("Georgia"))
    }

    func testPartialOrUnknownStoredValuesKeepTheDefaults() throws {
        let json = #"{"numbersHeadings": true, "lineSpacing": "enormous", "tableDensity": "compact"}"#
        let settings = try JSONDecoder().decode(IDEMarkdownPreviewSettings.self, from: Data(json.utf8))
        XCTAssertTrue(settings.numbersHeadings)
        XCTAssertEqual(settings.tableDensity, .compact)
        XCTAssertEqual(settings.lineSpacing, .normal, "an unknown value falls back")
        XCTAssertEqual(settings.typeface, .editor)
        XCTAssertTrue(settings.opensDiagramsOnClick)
        XCTAssertFalse(settings.sideBySide, "a value saved before the alongside option keeps covering")
    }

    func testStoredAndLoadedThroughUserDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "umbra-test.markdown-\(UUID().uuidString)"))
        XCTAssertEqual(IDEMarkdownPreviewSettings.load(from: defaults), IDEMarkdownPreviewSettings())
        var settings = IDEMarkdownPreviewSettings()
        settings.justifiesParagraphs = true
        settings.lineLength = 90
        settings.save(to: defaults)
        XCTAssertEqual(IDEMarkdownPreviewSettings.load(from: defaults), settings)
    }

    func testSettingsTravelWithTheSnapshotAndAnOlderFileLeavesThemAlone() throws {
        var snapshot = IDEPreferences.shared.snapshot()
        var custom = IDEMarkdownPreviewSettings()
        custom.headingAlignment = .center
        custom.typeface = .system
        snapshot.markdownPreview = custom
        let encoded = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(IDEPreferencesSnapshot.self, from: encoded).markdownPreview, custom)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "markdownPreview")
        let older = try JSONSerialization.data(withJSONObject: object)
        XCTAssertNil(try JSONDecoder().decode(IDEPreferencesSnapshot.self, from: older).markdownPreview)
    }

    func testAppearanceChoiceRoundTrips() {
        for appearance in [MarkdownPreviewAppearance.light, .dark, nil] {
            XCTAssertEqual(IDEMarkdownPreviewAppearanceChoice(appearance).appearance, appearance)
        }
    }

    func testTheMarkdownPageFollowsTheEditorPageAndIsFoundBySearch() {
        let order = IDEPreferencesDomain.ordered(with: []).map(\.id)
        XCTAssertEqual(order.firstIndex(of: "markdown"), order.firstIndex(of: "editor").map { $0 + 1 })
        for term in ["line length", "number headings", "justify", "table columns", "serif"] {
            XCTAssertTrue(IDEPreferencesDomain.markdown.matches(term), term)
        }
    }
}
