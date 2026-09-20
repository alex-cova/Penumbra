import AppKit
import XCTest
@testable import Penumbra

/// Tests for `MarkdownPreviewView.preferredContentSize(forWidth:)` — the intrinsic-size query a
/// host uses to size an inline (non-scrolling) embed of the preview, e.g. a chat bubble, without
/// ever laying the view out on screen.
final class MarkdownPreviewViewSizingTests: XCTestCase {
    @MainActor
    func testPreferredContentSizeIsZeroWithoutDocument() {
        let preview = MarkdownPreviewView(frame: .zero)
        XCTAssertEqual(preview.preferredContentSize(forWidth: 320), .zero)
    }

    @MainActor
    func testPreferredContentSizeMatchesLayoutContentSizeBeforeAnyOnScreenLayout() {
        let preview = MarkdownPreviewView(frame: .zero)
        preview.document = MarkdownPreviewDocument.parse("# Title\n\nSome body text.")

        // Queried with no window, no superview, and `layoutSubtreeIfNeeded()` never called.
        let queried = preview.preferredContentSize(forWidth: 320)

        let expected = MarkdownPreviewLayout.layout(
            document: preview.document!,
            style: preview.style,
            width: 320
        ).contentSize
        XCTAssertEqual(queried, expected)
    }

    @MainActor
    func testPreferredContentSizeGrowsWithDocumentContent() {
        let preview = MarkdownPreviewView(frame: .zero)
        preview.document = MarkdownPreviewDocument.parse("Short.")
        let shortSize = preview.preferredContentSize(forWidth: 320)

        preview.document = MarkdownPreviewDocument.parse(
            "# Heading\n\nA paragraph.\n\n- One\n- Two\n- Three\n\nAnother paragraph."
        )
        let longSize = preview.preferredContentSize(forWidth: 320)

        XCTAssertGreaterThan(longSize.height, shortSize.height)
    }

    @MainActor
    func testPreferredContentSizeClampsNonPositiveWidth() {
        let preview = MarkdownPreviewView(frame: .zero)
        preview.document = MarkdownPreviewDocument.parse("Hello")
        let size = preview.preferredContentSize(forWidth: 0)
        XCTAssertGreaterThan(size.width, 0)
    }
}
