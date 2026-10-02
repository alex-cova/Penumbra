import Foundation
import XCTest
import PenumbraLanguages
import TreeSitterJavaPenumbra
@testable import Penumbra

/// The Java highlights query lists specific patterns before the `(identifier) @variable`
/// fallback. On a tie the earlier pattern must be the one applied last.
final class JavaHighlightQueryTests: XCTestCase {
    private let source = #"""
    import java.util.List;
    import static java.util.Objects.requireNonNull;

    @Deprecated
    public class Sample {
        @Override
        @javax.annotation.Nullable
        public String name() { return String.valueOf(List.of(1)); }
    }

    sealed interface Shape permits Circle {}
    record Circle(double radius) implements Shape {}
    enum Color { RED, Green }
    class Holder {
        int count;
        void run(int amount) {
            var total = Color.Green;
            String text = """
                hi
                """;
            boolean match = shapeValue instanceof Circle(double radiusValue) && radiusValue > 0;
            String escaped = "tab\there";
            int r = switch (amount) { default -> { yield count; } };
        }
    }
    """#

    func testAnnotationNamesAreAttributes() {
        XCTAssertEqual(winningCapture(for: "Deprecated"), "attribute")
        XCTAssertEqual(winningCapture(for: "Override"), "attribute")
        XCTAssertEqual(winningCapture(for: "Nullable"), "attribute")
    }

    func testCapitalizedReceiversAreTypes() {
        XCTAssertEqual(winningCapture(for: "String", occurrence: 1), "type")
        XCTAssertEqual(winningCapture(for: "List", occurrence: 1), "type")
    }

    func testImportedClassIsAType() {
        XCTAssertEqual(winningCapture(for: "List"), "type")
        XCTAssertEqual(winningCapture(for: "util"), "variable")
    }

    func testModernKeywords() {
        for word in ["sealed", "permits", "record", "yield", "var"] {
            XCTAssertEqual(winningCapture(for: word), "keyword", word)
        }
    }

    func testRecordNameAndComponents() {
        XCTAssertEqual(winningCapture(for: "Circle", occurrence: 0), "type")
        XCTAssertEqual(winningCapture(for: "radius"), "variable.parameter")
    }

    func testEnumConstantFieldAndParameter() {
        XCTAssertEqual(winningCapture(for: "RED"), "constant")
        XCTAssertEqual(winningCapture(for: "Green"), "constant")
        XCTAssertEqual(winningCapture(for: "Green", occurrence: 1), "property")
        XCTAssertEqual(winningCapture(for: "count"), "property")
        XCTAssertEqual(winningCapture(for: "amount"), "variable.parameter")
    }

    func testGrammarCoversJava21Syntax() {
        XCTAssertEqual(winningCapture(for: "Circle", occurrence: 1), "type")
        XCTAssertEqual(winningCapture(for: "double", occurrence: 1), "type.builtin")
        XCTAssertEqual(winningCapture(for: "\\t"), "string.escape")
        // A text block is one string, not an error.
        XCTAssertEqual(winningCapture(for: "hi"), nil)
    }

    /// Name of the capture applied last (the one that paints) at the `occurrence`th `word`.
    private func winningCapture(for word: String, occurrence: Int = 0) -> String? {
        let stringView = StringView(string: source)
        let lineManager = LineManager(stringView: stringView)
        lineManager.rebuild()
        let mode = TreeSitterInternalLanguageMode(
            language: TreeSitterLanguage.java.internalLanguage,
            languageProvider: nil,
            stringView: stringView,
            lineManager: lineManager
        )
        mode.parse()
        let ns = source as NSString
        var searchRange = NSRange(location: 0, length: ns.length)
        var found = NSRange(location: NSNotFound, length: 0)
        for _ in 0 ... occurrence {
            found = ns.range(of: word, options: [], range: searchRange)
            guard found.location != NSNotFound else { return nil }
            searchRange = NSRange(location: found.upperBound, length: ns.length - found.upperBound)
        }
        let start = ByteCount(utf16Length: found.location)
        let captures = mode.captures(in: ByteRange(from: 0, to: stringView.byteCount))
        return captures.last { $0.byteRange.location == start && $0.byteRange.length == ByteCount(utf16Length: found.length) }?.name
    }
}
