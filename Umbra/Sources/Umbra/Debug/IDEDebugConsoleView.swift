import AppKit
import SwiftUI

/// Read-only live view of a debug session's console. Appends only the chunks it has not shown yet,
/// and trims the front of its text when the log dropped old chunks, so a program that prints
/// without end costs each update the size of the new output, not of the whole console.
struct IDEDebugConsoleView: NSViewRepresentable {
    let log: IDEDebugConsoleLog
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

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = IDEAppearance.NSToken.editor
        textView.textColor = IDEAppearance.NSToken.foreground
        textView.font = IDEEditorFonts.nsFont(familyName: fontName, size: CGFloat(fontSize))
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
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
    final class Coordinator {
        weak var textView: NSTextView?
        var lastRunID: UUID?
        var lastFontName: String?
        var lastFontSize: Double?
        /// Sequence of the last chunk in the text, or -1.
        private var lastSequence = -1
        /// Character counts of the chunks in the text, oldest first; `lengths[i]` is the chunk
        /// with sequence `firstSequence + i`.
        private var lengths: [Int] = []
        private var firstSequence = 0

        func render(_ log: IDEDebugConsoleLog, fontName: String, fontSize: Double, fullReplace: Bool) {
            guard let textView, let textStorage = textView.textStorage else { return }
            let font = IDEEditorFonts.nsFont(familyName: fontName, size: CGFloat(fontSize))
            let wasAtBottom = isScrolledToBottom(textView)

            if fullReplace {
                textStorage.setAttributedString(NSAttributedString(string: ""))
                lengths = []
                lastSequence = -1
                firstSequence = log.droppedCount
                lastRunID = log.runID
                lastFontName = fontName
                lastFontSize = fontSize
            }

            let chunks = log.chunks
            let firstKept = log.droppedCount
            // Text older than the log's oldest chunk goes. A chunk the view never showed and the log
            // already dropped is simply skipped.
            if firstSequence < firstKept {
                let drop = min(firstKept - firstSequence, lengths.count)
                if drop > 0 {
                    textStorage.deleteCharacters(in: NSRange(location: 0, length: lengths.prefix(drop).reduce(0, +)))
                    lengths.removeFirst(drop)
                }
                firstSequence = firstKept
            }

            let start = max(0, lastSequence + 1 - firstKept)
            guard start < chunks.count else { return }
            let appended = NSMutableAttributedString()
            for chunk in chunks[start...] {
                let text = chunk.endsLine ? chunk.text + "\n" : chunk.text
                appended.append(NSAttributedString(string: text, attributes: [
                    .font: font,
                    .foregroundColor: Self.color(for: chunk.stream)
                ]))
                lengths.append((text as NSString).length)
                lastSequence = chunk.sequence
            }
            textStorage.append(appended)

            if wasAtBottom {
                textView.scrollToEndOfDocument(nil)
            }
        }

        private static func color(for stream: IDEDebugConsoleLog.Stream) -> NSColor {
            switch stream {
            case .out: IDEAppearance.NSToken.foreground
            case .err: IDEAppearance.NSToken.error
            case .note: IDEAppearance.NSToken.muted
            case .log: IDEAppearance.NSToken.accent
            }
        }

        /// Only auto-scroll while the reader has not scrolled up to look at earlier output.
        private func isScrolledToBottom(_ textView: NSTextView) -> Bool {
            guard let scrollView = textView.enclosingScrollView else { return true }
            let visibleMaxY = scrollView.contentView.bounds.maxY
            let documentHeight = scrollView.documentView?.bounds.height ?? 0
            return documentHeight - visibleMaxY < 24
        }
    }
}
