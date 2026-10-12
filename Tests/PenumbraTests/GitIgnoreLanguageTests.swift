import AppKit
import XCTest
import PenumbraLanguages
@testable import Penumbra

/// The vendored `tree-sitter-gitignore` grammar with Penumbra's own highlight query: the query must
/// compile against the grammar, comments and patterns must get different colors, and the file names
/// ignore files go by must map to the language.
final class GitIgnoreLanguageTests: XCTestCase {
    private static let sample = """
    # build output
    build/
    *.log
    !keep.log
    docs/**/*.tmp
    file[0-9].txt\n
    """

    func testIgnoreFileNamesMapToTheLanguage() {
        for name in [".gitignore", ".dockerignore", ".npmignore", ".eslintignore", ".prettierignore"] {
            XCTAssertEqual(LanguageIdentifier.identifier(for: URL(fileURLWithPath: "/project/\(name)")), "gitignore", name)
        }
        XCTAssertNotEqual(LanguageIdentifier.identifier(for: URL(fileURLWithPath: "/project/ignore.txt")), "gitignore")
    }

    func testTheGrammarResolvesAndHasALineCommentPrefix() {
        BundledLanguages.resetCacheForTesting()
        let language = TreeSitterLanguage.bundled(forIdentifier: "gitignore")
        XCTAssertNotNil(language)
        XCTAssertEqual(language?.lineCommentPrefix, "#")
    }

    func testCommentsWildcardsAndNegationAreColoredApart() {
        let theme = DefaultTheme()
        let highlighted = StringSyntaxHighlighter(theme: theme, language: .gitIgnore).syntaxHighlight(Self.sample)
        let text = highlighted.string as NSString
        func color(of needle: String, offset: Int = 0) -> NSColor? {
            let range = text.range(of: needle)
            XCTAssertNotEqual(range.location, NSNotFound, needle)
            return highlighted.attribute(.foregroundColor, at: range.location + offset, effectiveRange: nil) as? NSColor
        }
        let comment = color(of: "# build output")
        let literal = color(of: "build/")
        let wildcard = color(of: "*.log")
        let negation = color(of: "!keep.log")
        XCTAssertNotNil(comment)
        XCTAssertNotEqual(comment, literal, "a comment is not drawn like a pattern")
        XCTAssertNotEqual(wildcard, literal, "a wildcard is not drawn like a literal")
        XCTAssertNotEqual(negation, literal, "a negation mark is not drawn like a literal")
    }
}
