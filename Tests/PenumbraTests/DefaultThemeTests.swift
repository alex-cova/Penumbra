import XCTest
@testable import Penumbra

final class DefaultThemeTests: XCTestCase {
    /// `DefaultTheme` used to resolve its colors from `Theme.xcassets` via `Bundle.module`, which
    /// is known to fail to resolve under certain static-linking configurations — and when it did,
    /// every syntax-highlight token silently collapsed to the same fallback color, defeating
    /// syntax highlighting entirely. Colors are now defined directly in code, independent of the
    /// asset catalog resolving at all. This asserts the distinct token categories actually get
    /// distinct colors.
    func testSyntaxHighlightTokenCategoriesGetDistinctColors() {
        let theme = DefaultTheme()
        // One representative highlight name per distinct color bucket in DefaultTheme.
        let names = ["comment", "string", "keyword", "type", "number", "function", "constructor", "property", "punctuation", "variable.builtin"]
        let colors = names.compactMap { theme.textColor(for: $0) }
        XCTAssertEqual(colors.count, names.count, "Every listed highlight name should resolve to a color")

        let components = colors.map { $0.cgColor.components ?? [] }
        for i in 0 ..< components.count {
            for j in (i + 1) ..< components.count where j < components.count {
                XCTAssertNotEqual(components[i], components[j], "\(names[i]) and \(names[j]) should not share a color")
            }
        }
    }

    func testSwiftCaptureNamesResolveToColors() {
        let theme = DefaultTheme()
        XCTAssertNotNil(theme.textColor(for: "attribute"))
        XCTAssertNotNil(theme.textColor(for: "variable.member"))
        XCTAssertNotNil(theme.textColor(for: "variable.parameter"))
    }

    func testDiffCaptureNamesResolveToDistinctColors() {
        let theme = DefaultTheme()
        XCTAssertNotNil(theme.textColor(for: "constant"))
        let plus = theme.textColor(for: "diff.plus")
        let minus = theme.textColor(for: "diff.minus")
        let delta = theme.textColor(for: "diff.delta")
        XCTAssertNotNil(plus)
        XCTAssertNotNil(minus)
        XCTAssertNotNil(delta)
        XCTAssertNotEqual(plus?.cgColor.components, minus?.cgColor.components)
        XCTAssertNotEqual(plus?.cgColor.components, delta?.cgColor.components)
        XCTAssertNotEqual(minus?.cgColor.components, delta?.cgColor.components)
    }

    func testRelatedTokensIntentionallyShareAColor() {
        let theme = DefaultTheme()
        XCTAssertEqual(theme.textColor(for: "property")?.cgColor.components, theme.textColor(for: "constant.builtin")?.cgColor.components)
        XCTAssertEqual(theme.textColor(for: "property")?.cgColor.components, theme.textColor(for: "constant.character")?.cgColor.components)
        XCTAssertEqual(theme.textColor(for: "punctuation")?.cgColor.components, theme.textColor(for: "operator")?.cgColor.components)
    }

    func testEmphasisHighlightNamesCarryTraitsRatherThanColor() {
        let theme = DefaultTheme()
        XCTAssertNil(theme.textColor(for: "markup.bold"))
        XCTAssertNil(theme.textColor(for: "markup.italic"))
        XCTAssertTrue(theme.fontTraits(for: "markup.bold").contains(.bold))
        XCTAssertTrue(theme.fontTraits(for: "markup.italic").contains(.italic))
        XCTAssertTrue(theme.fontTraits(for: "keyword").contains(.bold))
    }

    func testMarkdownStructureNamesAreStyled() {
        let theme = DefaultTheme()
        for name in ["markup.heading.1", "markup.heading.6", "markup.list", "markup.list.checked", "markup.list.unchecked",
                     "markup.table.header", "markup.strikethrough"] {
            XCTAssertNotNil(theme.textColor(for: name), "Expected a color for \(name)")
        }
        // Levelled headings share the plain heading style; scaling is a PaletteTheme opt-in.
        XCTAssertEqual(theme.textColor(for: "markup.heading.2")?.cgColor.components, theme.textColor(for: "markup.heading")?.cgColor.components)
        XCTAssertTrue(theme.fontTraits(for: "markup.heading.2").contains(.bold))
        XCTAssertTrue(theme.fontTraits(for: "markup.table.header").contains(.bold))
        XCTAssertNil(theme.font(for: "markup.heading.1"))
    }

    func testInternedSyntaxColorsAreReusedAcrossLookups() {
        let theme = DefaultTheme()
        let first = theme.textColor(for: "keyword")
        let second = theme.textColor(for: "keyword")
        let fromAlias = theme.textColor(for: "keyword.operator")
        XCTAssertNotNil(first)
        XCTAssertTrue(first === second, "DefaultTheme should intern dynamic token colors instead of allocating per lookup")
        XCTAssertTrue(first === fromAlias, "More specific highlight names that resolve to keyword should share the interned color")
    }

    func testChromeColorsResolveWithoutTheAssetCatalog() {
        let theme = DefaultTheme()
        // These construct successfully even though nothing here touches `Theme.xcassets` — a
        // regression here would mean DefaultTheme started depending on the resource bundle again.
        XCTAssertNotNil(theme.textColor)
        XCTAssertNotNil(theme.gutterBackgroundColor)
        XCTAssertNotNil(theme.selectedLineBackgroundColor)
        XCTAssertNotNil(theme.invisibleCharactersColor)
    }

    func testMethodSeparatorAndOccurrenceColorsResolveInBothAppearances() {
        let theme = DefaultTheme()
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            guard let appearance = NSAppearance(named: appearanceName) else {
                continue
            }
            appearance.performAsCurrentDrawingAppearance {
                XCTAssertNotNil(theme.methodSeparatorColor.cgColor.components)
                let occurrence = theme.occurrenceHighlightColor.cgColor
                XCTAssertNotNil(occurrence.components)
                // The occurrence highlight is translucent so glyphs stay readable beneath it.
                XCTAssertLessThan(occurrence.alpha, 1)
            }
        }
        XCTAssertGreaterThan(theme.methodSeparatorWidth, 0)
    }

    func testCustomThemeGetsProtocolDefaultsForNewColors() {
        // A theme that predates these properties still compiles and gets sensible defaults.
        final class LegacyTheme: MinimalThemeStub {}
        let theme = LegacyTheme()
        XCTAssertEqual(theme.methodSeparatorColor, theme.pageGuideHairlineColor)
        XCTAssertGreaterThan(theme.methodSeparatorWidth, 0)
        XCTAssertLessThan(theme.occurrenceHighlightColor.cgColor.alpha, 1)
    }
}

/// Minimal `Theme` conformer that implements only the historically-required members, to prove the
/// protocol extension supplies `methodSeparatorColor` / `methodSeparatorWidth` /
/// `occurrenceHighlightColor` defaults.
class MinimalThemeStub: Penumbra.Theme {
    let font = UIFont.systemFont(ofSize: 12)
    let textColor = UIColor.labelColor
    let gutterBackgroundColor = UIColor.textBackgroundColor
    let gutterHairlineColor = UIColor.separatorColor
    let lineNumberColor = UIColor.secondaryLabelColor
    let lineNumberFont = UIFont.systemFont(ofSize: 12)
    let selectedLineBackgroundColor = UIColor.clear
    let selectedLinesLineNumberColor = UIColor.labelColor
    let selectedLinesGutterBackgroundColor = UIColor.textBackgroundColor
    let invisibleCharactersColor = UIColor.secondaryLabelColor
    let pageGuideHairlineColor = UIColor.separatorColor
    let pageGuideBackgroundColor = UIColor.textBackgroundColor
    let markedTextBackgroundColor = UIColor.clear
    func textColor(for highlightName: String) -> UIColor? { nil }
}
