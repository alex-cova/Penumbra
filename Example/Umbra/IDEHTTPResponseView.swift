import AppKit
import SwiftUI

/// The response log's text view. It takes focus on a click and answers ⌘C and ⌘A itself, so
/// copying does not depend on the menu bar's Copy item finding this view in the responder chain
/// (the editor and the terminal share the window).
private final class IDEResponseTextView: NSTextView {
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard window?.firstResponder === self, modifiers == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c" where selectedRange().length > 0:
            copy(nil)
            return true
        case "a":
            selectAll(nil)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}

/// Read-only live view of `IDEHTTPSupport.responseLog`, hosted as the "HTTP" tab in the bottom panel.
struct IDEHTTPResponseView: NSViewRepresentable {
    let log: HTTPResponseLog
    let fontName: String
    let fontSize: Double

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = IDEAppearance.NSToken.editor

        let textView = IDEResponseTextView()
        textView.isEditable = false
        textView.isSelectable = true
        // ⌘F while this view has focus opens the find bar (`IDEWorkspace.showFind` routes it here).
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = IDEAppearance.NSToken.editor
        textView.textColor = IDEAppearance.NSToken.foreground
        textView.insertionPointColor = IDEAppearance.NSToken.foreground
        textView.font = IDEEditorFonts.nsFont(familyName: fontName, size: CGFloat(fontSize))
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.delegate = context.coordinator
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.controlAccentColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand
        ]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView

        context.coordinator.textView = textView
        context.coordinator.render(log, fontName: fontName, fontSize: fontSize, fullReplace: true)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let fullReplace = context.coordinator.lastRunID != log.runID
            || context.coordinator.lastFontName != fontName
            || context.coordinator.lastFontSize != fontSize
        context.coordinator.render(log, fontName: fontName, fontSize: fontSize, fullReplace: fullReplace)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: NSTextView?
        var lastRunID: UUID?
        var lastFontName: String?
        var lastFontSize: Double?
        private var renderedLineCount = 0

        func render(_ log: HTTPResponseLog, fontName: String, fontSize: Double, fullReplace: Bool) {
            guard let textView, let textStorage = textView.textStorage else { return }
            let font = IDEEditorFonts.nsFont(familyName: fontName, size: CGFloat(fontSize))
            let wasAtBottom = isScrolledToBottom(textView)

            if fullReplace {
                textStorage.setAttributedString(NSAttributedString(string: ""))
                renderedLineCount = 0
                lastRunID = log.runID
                lastFontName = fontName
                lastFontSize = fontSize
            }

            guard renderedLineCount < log.lines.count else { return }
            let newLines = log.lines[renderedLineCount...]
            for line in newLines {
                let attributed = Self.attributedString(for: line, font: font)
                if textStorage.length > 0 {
                    textStorage.append(NSAttributedString(string: "\n"))
                }
                textStorage.append(attributed)
            }
            renderedLineCount = log.lines.count

            if wasAtBottom {
                textView.scrollToEndOfDocument(nil)
            }
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL, url.isFileURL else { return false }
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return true
        }

        private func isScrolledToBottom(_ textView: NSTextView) -> Bool {
            guard let scrollView = textView.enclosingScrollView else { return true }
            let visibleMaxY = scrollView.contentView.bounds.maxY
            let documentHeight = scrollView.documentView?.bounds.height ?? 0
            return documentHeight - visibleMaxY < 24
        }

        private static func attributedString(for line: HTTPResponseLog.Line, font: NSFont) -> NSAttributedString {
            let color: NSColor
            switch line {
            case .savedFile(let url):
                let result = NSMutableAttributedString(string: line.text + "  ", attributes: [
                    .font: font,
                    .foregroundColor: IDEAppearance.NSToken.muted
                ])
                result.append(NSAttributedString(string: "Reveal in Finder", attributes: [
                    .font: font,
                    .link: url
                ]))
                return result
            case .note, .request:
                color = IDEAppearance.NSToken.muted
            case .response:
                color = IDEAppearance.NSToken.foreground
            case .error:
                color = NSColor.systemRed
            }
            return NSAttributedString(string: line.text, attributes: [
                .font: font,
                .foregroundColor: color
            ])
        }
    }
}
