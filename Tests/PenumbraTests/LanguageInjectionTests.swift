import Foundation
import PenumbraLanguages
import TestTreeSitterLanguages
import XCTest
@testable import Penumbra

/// Language injections: persistent `// language=ID` comments plus the temporary Inject-language
/// action highlight a string literal's content with the named language. Intelligence inside
/// fragments is out of scope — these assert capture names only.
final class LanguageInjectionTests: XCTestCase {
    // MARK: - Comment injections

    func testCommentOnLineAboveInjectsSQLInJavaScript() {
        let text = "// language=sql\nconst q = \"SELECT * FROM t WHERE x = 1\";\n"
        let names = captureNamesByByteRange(language: .javaScript, text: text)
        let content = byteRange(of: "SELECT * FROM t WHERE x = 1", in: text)
        let overContent = names.filter { $0.key.overlaps(content) }.flatMap(\.value)
        XCTAssertTrue(overContent.contains("keyword"), "Expected SQL keyword over the string content, got \(overContent)")
    }

    func testSameLineCommentInjectsSQLInJavaScript() {
        let text = "const q = \"SELECT * FROM t\"; // language=sql\n"
        // A trailing comment attaches to nothing (the string is before it): no injection.
        let names = captureNamesByByteRange(language: .javaScript, text: text)
        let content = byteRange(of: "SELECT * FROM t", in: text)
        let overContent = names.filter { $0.key.overlaps(content) }.flatMap(\.value)
        XCTAssertFalse(overContent.contains("keyword"), "Trailing comment must not inject, got \(overContent)")

        // A block comment on the same line before the string attaches to it.
        let beforeText = "/* language=sql */ const q = \"SELECT * FROM t\";\n"
        let beforeNames = captureNamesByByteRange(language: .javaScript, text: beforeText)
        let beforeContent = byteRange(of: "SELECT * FROM t", in: beforeText)
        let beforeOver = beforeNames.filter { $0.key.overlaps(beforeContent) }.flatMap(\.value)
        XCTAssertTrue(beforeOver.contains("keyword"), "Same-line comment before the string must inject, got \(beforeOver)")
    }

    func testCommentInjectsSQLInJava() {
        let text = "class A {\n// language=sql\nString q = \"SELECT * FROM t\";\n}\n"
        let names = captureNamesByByteRange(language: .java, text: text)
        let content = byteRange(of: "SELECT * FROM t", in: text)
        let overContent = names.filter { $0.key.overlaps(content) }.flatMap(\.value)
        XCTAssertTrue(overContent.contains("keyword"), "Expected SQL keyword over the Java string content, got \(overContent)")
    }

    func testCommentInjectsSQLInSwift() {
        let text = "// language=sql\nlet q = \"SELECT * FROM t\"\n"
        let names = captureNamesByByteRange(language: .swift, text: text)
        let content = byteRange(of: "SELECT * FROM t", in: text)
        let overContent = names.filter { $0.key.overlaps(content) }.flatMap(\.value)
        XCTAssertTrue(overContent.contains("keyword"), "Expected SQL keyword over the Swift string content, got \(overContent)")
    }

    func testSwiftInterpolationIsExcluded() {
        let text = "// language=sql\nlet q = \"SELECT \\(table) FROM t\"\n"
        let names = captureNamesByByteRange(language: .swift, text: text)
        let content = byteRange(of: "SELECT \\(table) FROM t", in: text)
        let overContent = names.filter { $0.key.overlaps(content) }.flatMap(\.value)
        XCTAssertTrue(overContent.contains("keyword"), "SQL must still parse around the interpolation, got \(overContent)")
    }

    func testCommentInjectsSQLInPython() {
        let text = "# language=sql\nq = \"SELECT * FROM t\"\n"
        let names = captureNamesByByteRange(language: .python, text: text)
        let content = byteRange(of: "SELECT * FROM t", in: text)
        let overContent = names.filter { $0.key.overlaps(content) }.flatMap(\.value)
        XCTAssertTrue(overContent.contains("keyword"), "Expected SQL keyword over the Python string content, got \(overContent)")
    }

    func testCommentInjectionSkipsBlankLines() {
        let text = "// language=sql\n\nconst q = \"SELECT * FROM t\";\n"
        let names = captureNamesByByteRange(language: .javaScript, text: text)
        let content = byteRange(of: "SELECT * FROM t", in: text)
        let overContent = names.filter { $0.key.overlaps(content) }.flatMap(\.value)
        XCTAssertTrue(overContent.contains("keyword"), "Comment must attach across a blank line, got \(overContent)")
    }

    func testUnknownLanguageIDIsIgnored() {
        let text = "// language=xyzzy\nconst q = \"SELECT * FROM t\";\n"
        let names = captureNamesByByteRange(language: .javaScript, text: text)
        let content = byteRange(of: "SELECT * FROM t", in: text)
        let overContent = names.filter { $0.key.overlaps(content) }.flatMap(\.value)
        XCTAssertFalse(overContent.contains("keyword"), "Unknown language must not inject, got \(overContent)")
        XCTAssertTrue(overContent.contains("string"), "Host string highlight must survive, got \(overContent)")
    }

    func testCommentLanguageAliasResolves() {
        let text = "# language=js\nq = \"const x = 1\"\n"
        let names = captureNamesByByteRange(language: .python, text: text)
        let content = byteRange(of: "const x = 1", in: text)
        let overContent = names.filter { $0.key.overlaps(content) }.flatMap(\.value)
        XCTAssertTrue(overContent.contains("keyword"), "Expected JS keyword via `js` alias, got \(overContent)")
    }

    // MARK: - Precedence

    func testManualInjectionSuppressesAutomaticInjection() {
        // `css` tagged template auto-injects CSS (`property` for `color: red`); the manual SQL
        // comment on the same template wins and the CSS layer is dropped whole.
        let text = "// language=sql\nconst s = css`SELECT { color: red }`;\n"
        let names = captureNamesByByteRange(language: .javaScript, text: text)
        let content = byteRange(of: "SELECT { color: red }", in: text)
        let overContent = names.filter { $0.key.overlaps(content) }.flatMap(\.value)
        XCTAssertTrue(overContent.contains("keyword"), "Expected SQL keyword from the manual injection, got \(overContent)")
        XCTAssertFalse(overContent.contains("property"), "Automatic CSS injection must be suppressed, got \(overContent)")
    }

    func testTemporaryInjectionWinsOverComment() {
        let text = "// language=sql\nconst q = '{ \"a\": 1 }';\n"
        let utf16 = (text as NSString).range(of: "{ \"a\": 1 }")
        let provider = StubManualInjectionProvider()
        provider.injections = [ManualLanguageInjection(utf16Range: utf16, languageIdentifier: "json", source: .temporary)]
        let names = captureNamesByByteRange(language: .javaScript, text: text, manualProvider: provider)
        let content = byteRange(of: "{ \"a\": 1 }", in: text)
        let overContent = names.filter { $0.key.overlaps(content) }.flatMap(\.value)
        XCTAssertTrue(overContent.contains("number") || overContent.contains("property"),
                      "Expected JSON captures from the temporary injection, got \(overContent)")
        XCTAssertFalse(overContent.contains("keyword"), "Comment SQL injection must lose to temporary JSON, got \(overContent)")
    }

    func testTemporaryInjectionWithoutComment() {
        let text = "const q = \"SELECT * FROM t\";\n"
        let utf16 = (text as NSString).range(of: "SELECT * FROM t")
        let provider = StubManualInjectionProvider()
        provider.injections = [ManualLanguageInjection(utf16Range: utf16, languageIdentifier: "sql", source: .temporary)]
        let names = captureNamesByByteRange(language: .javaScript, text: text, manualProvider: provider)
        let content = byteRange(of: "SELECT * FROM t", in: text)
        let overContent = names.filter { $0.key.overlaps(content) }.flatMap(\.value)
        XCTAssertTrue(overContent.contains("keyword"), "Expected SQL keyword from the temporary injection, got \(overContent)")
    }

    // MARK: - Interpolation

    func testTemplateSubstitutionIsExcluded() {
        let text = "// language=sql\nconst q = `SELECT ${x} FROM t`;\n"
        let names = captureNamesByByteRange(language: .javaScript, text: text)
        let content = byteRange(of: "SELECT ${x} FROM t", in: text)
        let overContent = names.filter { $0.key.overlaps(content) }.flatMap(\.value)
        XCTAssertTrue(overContent.contains("keyword"), "SQL must still parse around the substitution, got \(overContent)")
        let substitution = byteRange(of: "${x}", in: text)
        let overSubstitution = names.filter { $0.key.overlaps(substitution) }.flatMap(\.value)
        XCTAssertFalse(overSubstitution.contains("keyword"), "Substitution must not carry SQL captures, got \(overSubstitution)")
    }

    // MARK: - Edits

    func testEditBeforeFragmentKeepsInjection() {
        withSyncKeystrokeParse {
            let text = "// language=sql\nconst q = \"SELECT * FROM t\";\n"
            let (mode, stringView, lineManager) = makeMode(language: .javaScript, text: text)
            func keywords() -> [String] {
                let full = ByteRange(from: 0, to: (stringView.string as NSString).byteCount)
                return mode.captures(in: full).filter { $0.name == "keyword" }.map { _ in "keyword" }
            }
            XCTAssertFalse(keywords().isEmpty, "Precondition: SQL keyword present before edit")
            // Insert a line above the fragment; the injection must shift with it.
            let editHelper = TextEditHelper(stringView: stringView, lineManager: lineManager, lineEndings: .lf)
            _ = mode.textDidChange(editHelper.replaceText(in: NSRange(location: 0, length: 0), with: "// hello\n").textChange)
            XCTAssertFalse(keywords().isEmpty, "SQL keyword must survive an edit before the fragment")
        }
    }

    func testEditInsideFragmentReparses() {
        withSyncKeystrokeParse {
            let text = "// language=sql\nconst q = \"SELECT * FROM t\";\n"
            let (mode, stringView, lineManager) = makeMode(language: .javaScript, text: text)
            let editHelper = TextEditHelper(stringView: stringView, lineManager: lineManager, lineEndings: .lf)
            let target = (stringView.string as NSString).range(of: "FROM")
            _ = mode.textDidChange(editHelper.replaceText(in: target, with: "WHERE x = 1 OR").textChange)
            let full = ByteRange(from: 0, to: (stringView.string as NSString).byteCount)
            let names = Set(mode.captures(in: full).map(\.name))
            XCTAssertTrue(names.contains("keyword"), "SQL keyword must survive an edit inside the fragment, got \(names)")
            XCTAssertTrue(names.contains("number"), "New SQL content must highlight after the edit, got \(names)")
        }
    }

    func testTemporaryRangesShiftAcrossEdits() {
        withSyncKeystrokeParse {
            let text = "const q = \"SELECT * FROM t\";\n"
            let utf16 = (text as NSString).range(of: "SELECT * FROM t")
            let provider = StubManualInjectionProvider()
            provider.injections = [ManualLanguageInjection(utf16Range: utf16, languageIdentifier: "sql", source: .temporary)]
            let (mode, stringView, lineManager) = makeMode(language: .javaScript, text: text, manualProvider: provider)
            let editHelper = TextEditHelper(stringView: stringView, lineManager: lineManager, lineEndings: .lf)
            _ = mode.textDidChange(editHelper.replaceText(in: NSRange(location: 0, length: 0), with: "// pad\n").textChange)
            // The layer shifts its cache and writes it back so the store never goes stale.
            XCTAssertEqual(provider.injections.count, 1)
            let shifted = (stringView.string as NSString).range(of: "SELECT * FROM t")
            XCTAssertEqual(provider.injections[0].utf16Range, shifted, "Temporary range must shift with the edit")
            let full = ByteRange(from: 0, to: (stringView.string as NSString).byteCount)
            XCTAssertTrue(Set(mode.captures(in: full).map(\.name)).contains("keyword"),
                          "Injection must survive the shift")
        }
    }

    private func withSyncKeystrokeParse(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: PenumbraSyncKeystrokeParse.defaultsKey)
        defaults.set(true, forKey: PenumbraSyncKeystrokeParse.defaultsKey)
        defer { defaults.set(previous, forKey: PenumbraSyncKeystrokeParse.defaultsKey) }
        body()
    }

    // MARK: - Helpers

    private func captureNamesByByteRange(
        language: TreeSitterLanguage,
        text: String,
        manualProvider: ManualInjectionProviding? = nil
    ) -> [ByteRange: [String]] {
        let (mode, stringView, _) = makeMode(language: language, text: text, manualProvider: manualProvider)
        let full = ByteRange(from: 0, to: (stringView.string as NSString).byteCount)
        var result: [ByteRange: [String]] = [:]
        for capture in mode.captures(in: full) {
            result[capture.byteRange, default: []].append(capture.name)
        }
        return result
    }

    private func makeMode(
        language: TreeSitterLanguage,
        text: String,
        manualProvider: ManualInjectionProviding? = nil
    ) -> (TreeSitterInternalLanguageMode, StringView, LineManager) {
        let stringView = StringView(string: text)
        let lineManager = LineManager(stringView: stringView)
        lineManager.rebuild()
        let mode = TreeSitterInternalLanguageMode(
            language: language.internalLanguage,
            languageProvider: BundledLanguageProvider(),
            stringView: stringView,
            lineManager: lineManager,
            manualInjectionProvider: manualProvider)
        mode.parse()
        return (mode, stringView, lineManager)
    }

    private func byteRange(of needle: String, in text: String) -> ByteRange {
        let ns = (text as NSString).range(of: needle)
        XCTAssertNotEqual(ns.location, NSNotFound, "Fixture must contain \(needle)")
        return ByteRange(location: ByteCount(ns.location * 2), length: ByteCount(ns.length * 2))
    }
}

private final class StubManualInjectionProvider: ManualInjectionProviding {
    var injections: [ManualLanguageInjection] = []
    var shifted: [[ManualLanguageInjection]] = []
    func manualInjections() -> [ManualLanguageInjection] {
        injections
    }
    func manualInjectionsDidShift(_ injections: [ManualLanguageInjection]) {
        shifted.append(injections)
        self.injections = injections
    }
}
