import AppKit
import CoreText
import XCTest
@testable import Penumbra
@testable import Umbra

@MainActor
final class FontLigatureTests: XCTestCase {
    private var original: IDEPreferencesSnapshot?

    override func setUp() {
        super.setUp()
        original = IDEPreferences.shared.snapshot()
    }

    override func tearDown() {
        if let original {
            IDEPreferences.shared.restore(from: original)
        }
        super.tearDown()
    }

    private func ligatureFont() throws -> NSFont {
        for name in ["JetBrainsMono-Regular", "FiraCode-Regular", "CascadiaCode-Regular"] {
            if let font = NSFont(name: name, size: 13) {
                return font
            }
        }
        throw XCTSkip("No ligature font (JetBrains Mono, Fira Code, Cascadia Code) is installed")
    }

    private func glyphNames(_ font: NSFont, _ text: String = "a != b") -> [String] {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        var names: [String] = []
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let runFont = (CTRunGetAttributes(run) as NSDictionary)[NSAttributedString.Key.font] as! CTFont
            let graphicsFont = CTFontCopyGraphicsFont(runFont, nil)
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            names += glyphs.map { (graphicsFont.name(for: $0) as String?) ?? "?" }
        }
        return names
    }

    private func hasLigature(_ names: [String]) -> Bool {
        names.contains { $0.contains("_") || $0.hasSuffix(".liga") }
    }

    func testLigaturesFormOnlyWhenEnabled() throws {
        let font = try ligatureFont()
        XCTAssertTrue(hasLigature(glyphNames(font.withLigatures(true))))
        let off = glyphNames(font.withLigatures(false))
        XCTAssertFalse(hasLigature(off), "\(off)")
        XCTAssertTrue(off.contains("exclam") && off.contains("equal"), "\(off)")
    }

    func testDerivedBoldAndItalicFontsKeepTheSetting() throws {
        let off = try ligatureFont().withLigatures(false)
        for traits in [NSFontDescriptor.SymbolicTraits.bold, .italic] {
            let derived = try XCTUnwrap(NSFont(descriptor: off.fontDescriptor.withSymbolicTraits(traits), size: off.pointSize))
            XCTAssertFalse(hasLigature(glyphNames(derived)))
        }
    }

    func testCaretOffsetsDoNotDependOnLigatures() throws {
        let font = try ligatureFont()
        let text = "a != b -> c === d"
        func offsets(_ font: NSFont) -> [CGFloat] {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
            return (0...text.utf16.count).map { CTLineGetOffsetForStringIndex(line, $0, nil) }
        }
        XCTAssertEqual(offsets(font.withLigatures(true)), offsets(font.withLigatures(false)))
    }

    func testSnapshotRoundTripAndOlderSnapshotsDefaultToOff() throws {
        IDEPreferences.shared.fontLigatures = true
        let snapshot = IDEPreferences.shared.snapshot()
        XCTAssertTrue(snapshot.fontLigatures)
        let decoded = try JSONDecoder().decode(IDEPreferencesSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertTrue(decoded.fontLigatures)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        object.removeValue(forKey: "fontLigatures")
        let older = try JSONDecoder().decode(IDEPreferencesSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(older.fontLigatures)
    }

    func testPreferenceReachesTheEditorTheme() throws {
        _ = try ligatureFont()
        IDEPreferences.shared.fontName = "JetBrains Mono"
        IDEPreferences.shared.fontLigatures = false
        XCTAssertFalse(hasLigature(glyphNames(IDEEditorTheme.shared.current.font)))
        IDEPreferences.shared.fontLigatures = true
        XCTAssertTrue(hasLigature(glyphNames(IDEEditorTheme.shared.current.font)))
    }
}
