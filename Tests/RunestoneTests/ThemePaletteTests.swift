import XCTest
@testable import Runestone

final class ThemeCatalogTests: XCTestCase {
    func testCatalogIDsAreUniqueAndNonEmpty() {
        let ids = ThemeCatalog.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
        XCTAssertTrue(ids.allSatisfy { !$0.isEmpty })
        XCTAssertTrue(ids.contains(ThemeCatalog.defaultLightID))
        XCTAssertTrue(ids.contains(ThemeCatalog.defaultDarkID))
    }

    func testHextechLightMatchesOriginalHardcodedPalette() {
        let palette = ThemeCatalog.palette(id: ThemeCatalog.defaultLightID, fallbackDark: false)
        XCTAssertEqual(palette.background, 0xFFFFFF)
        XCTAssertEqual(palette.text, 0x1A1A1A)
        XCTAssertEqual(palette.gutterHairline, 0xE0E0E0)
        XCTAssertEqual(palette.lineNumber, 0x8E8E93)
        XCTAssertEqual(palette.selectedLineBackground, 0xF2F2F7)
        XCTAssertEqual(palette.selectedLinesLineNumber, 0x3A3A3C)
        XCTAssertEqual(palette.invisibleCharacters, 0xC7C7CC)
        XCTAssertEqual(palette.pageGuideHairline, 0xD1D1D6)
        XCTAssertEqual(palette.pageGuideBackground, 0xFAFAFA)
        XCTAssertEqual(palette.markedTextBackground, 0xFFE08A)
        XCTAssertEqual(palette.comment, 0x6B6B6B)
        XCTAssertEqual(palette.constant, 0x1C1C9C)
        XCTAssertEqual(palette.type, 0x267F99)
        XCTAssertEqual(palette.function, 0x795E26)
        XCTAssertEqual(palette.keyword, 0x9B229C)
        XCTAssertEqual(palette.number, 0x1C00CF)
        XCTAssertEqual(palette.property, 0x0451A5)
        XCTAssertEqual(palette.string, 0xA31515)
        XCTAssertEqual(palette.variableBuiltin, 0x0070C1)
        XCTAssertEqual(palette.punctuation, 0x383A42)
    }

    func testHextechDarkMatchesOriginalHardcodedPalette() {
        let palette = ThemeCatalog.palette(id: ThemeCatalog.defaultDarkID, fallbackDark: true)
        XCTAssertEqual(palette.background, 0x1E1E1E)
        XCTAssertEqual(palette.text, 0xE6E6E6)
        XCTAssertEqual(palette.gutterHairline, 0x2C2C2C)
        XCTAssertEqual(palette.lineNumber, 0x8E8E93)
        XCTAssertEqual(palette.selectedLineBackground, 0x2C2C2E)
        XCTAssertEqual(palette.selectedLinesLineNumber, 0xEBEBF5)
        XCTAssertEqual(palette.invisibleCharacters, 0x48484A)
        XCTAssertEqual(palette.pageGuideHairline, 0x3A3A3C)
        XCTAssertEqual(palette.pageGuideBackground, 0x1C1C1E)
        XCTAssertEqual(palette.markedTextBackground, 0x5C4B00)
        XCTAssertEqual(palette.comment, 0x6A9955)
        XCTAssertEqual(palette.constant, 0xD0A8FF)
        XCTAssertEqual(palette.type, 0x4EC9B0)
        XCTAssertEqual(palette.function, 0xDCDCAA)
        XCTAssertEqual(palette.keyword, 0xFC6C85)
        XCTAssertEqual(palette.number, 0xB5D4A8)
        XCTAssertEqual(palette.property, 0x9CDCFE)
        XCTAssertEqual(palette.string, 0xFC9A5D)
        XCTAssertEqual(palette.variableBuiltin, 0x569CD6)
        XCTAssertEqual(palette.punctuation, 0xD4D4D4)
    }

    func testUnknownIDFallsBackToDefaultForMode() {
        let light = ThemeCatalog.palette(id: "does-not-exist", fallbackDark: false)
        XCTAssertEqual(light.id, ThemeCatalog.defaultLightID)

        let dark = ThemeCatalog.palette(id: "does-not-exist", fallbackDark: true)
        XCTAssertEqual(dark.id, ThemeCatalog.defaultDarkID)
    }

    func testPalettesPreferringOrdersSuitedGroupFirst() {
        let darkFirst = ThemeCatalog.palettes(preferring: true)
        XCTAssertEqual(darkFirst.first?.isDark, true)
        XCTAssertEqual(Set(darkFirst.map(\.id)), Set(ThemeCatalog.all.map(\.id)))

        let lightFirst = ThemeCatalog.palettes(preferring: false)
        XCTAssertEqual(lightFirst.first?.isDark, false)
    }
}

final class PaletteThemeTests: XCTestCase {
    func testSyntaxHighlightTokenCategoriesGetDistinctColors() {
        let palette = ThemeCatalog.palette(id: ThemeCatalog.defaultDarkID, fallbackDark: true)
        let theme = PaletteTheme(size: 13, palette: palette, postscriptName: "Menlo-Regular")
        let names = ["comment", "string", "keyword", "type", "number", "function", "property", "punctuation", "variable.builtin"]
        let colors = names.compactMap { theme.textColor(for: $0) }
        XCTAssertEqual(colors.count, names.count)

        let components = colors.map { $0.cgColor.components ?? [] }
        for i in 0 ..< components.count {
            for j in (i + 1) ..< components.count {
                XCTAssertNotEqual(components[i], components[j], "\(names[i]) and \(names[j]) should not share a color")
            }
        }
    }

    func testHighlightNamePeelingResolvesNestedCapture() {
        let palette = ThemeCatalog.palette(id: ThemeCatalog.defaultLightID, fallbackDark: false)
        let theme = PaletteTheme(size: 13, palette: palette, postscriptName: "Menlo-Regular")
        XCTAssertEqual(
            theme.textColor(for: "string.special.key")?.cgColor.components,
            theme.textColor(for: "string")?.cgColor.components
        )
    }

    func testKeywordAndIncludeAreBold() {
        let palette = ThemeCatalog.palette(id: ThemeCatalog.defaultLightID, fallbackDark: false)
        let theme = PaletteTheme(size: 13, palette: palette, postscriptName: "Menlo-Regular")
        XCTAssertTrue(theme.fontTraits(for: "keyword").contains(.bold))
        XCTAssertTrue(theme.fontTraits(for: "include").contains(.bold))
        XCTAssertTrue(theme.fontTraits(for: "comment").isEmpty)
    }
}
