import XCTest
@testable import Runestone
import RunestoneLanguages

final class BundledLanguagesTests: XCTestCase {
    override func setUp() {
        super.setUp()
        BundledLanguages.resetCacheForTesting()
    }

    func testLanguageCacheReturnsSamePreparedInstance() {
        let first = BundledLanguages.language(forIdentifier: "json")
        let second = BundledLanguages.language(forIdentifier: "json")
        XCTAssertNotNil(first)
        XCTAssertTrue(first === second)
    }

    func testUnsupportedIdentifierReturnsNil() {
        XCTAssertNil(BundledLanguages.language(forIdentifier: "plain"))
        XCTAssertNil(BundledLanguages.language(forIdentifier: nil))
    }

    func testRustCAndCppResolveToGrammars() {
        XCTAssertNotNil(BundledLanguages.language(forIdentifier: "rust"))
        XCTAssertNotNil(BundledLanguages.language(forIdentifier: "c"))
        XCTAssertNotNil(BundledLanguages.language(forIdentifier: "cpp"))
    }

    func testIdentifierAliasesResolveToGrammars() {
        let aliases = ["xml", "groovy", "shell", "scss"]
        for identifier in aliases {
            XCTAssertNotNil(
                BundledLanguages.language(forIdentifier: identifier),
                identifier
            )
        }
    }

    func testLanguageIdentifierExtensionsWithBundledGrammarsResolve() {
        let expectedNil: Set<String> = ["plain"]
        let extensions = [
            "txt", "md", "json", "xml", "yaml", "toml", "swift", "java", "kt",
            "gradle", "js", "ts", "html", "css", "scss", "py", "rs", "go",
            "c", "cpp", "sh", "sql", "graphql", "http", "mmd"
        ]
        for ext in extensions {
            guard let identifier = LanguageIdentifier.identifier(forFileExtension: ext) else {
                continue
            }
            if expectedNil.contains(identifier) {
                XCTAssertNil(BundledLanguages.language(forIdentifier: identifier), ext)
            } else {
                XCTAssertNotNil(
                    BundledLanguages.language(forIdentifier: identifier),
                    "\(ext)→\(identifier)"
                )
            }
        }
    }

    func testMakeStateParsesDocumentOffMainThread() {
        let prepared = RunestoneStateBuilder.makeState(
            text: "{\"a\":1}\n",
            theme: PaletteTheme(
                size: 13,
                palette: ThemeCatalog.palette(id: ThemeCatalog.defaultLightID, fallbackDark: false),
                postscriptName: "Menlo-Regular"
            ),
            language: BundledLanguages.language(forIdentifier: "json")
        )
        XCTAssertNotNil(prepared.state.lengthOfLongestLine)
        XCTAssertGreaterThanOrEqual(prepared.state.lengthOfLongestLine ?? 0, 6)
    }
}
