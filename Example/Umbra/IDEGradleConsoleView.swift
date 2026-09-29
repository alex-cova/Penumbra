import AppKit
import JavaIntelligence
import SwiftUI

/// Read-only live view of `IDEJavaSupport.gradleConsole`, hosted as the "Gradle" tab in the bottom
/// panel (`IDETerminalPanel`). Renders incrementally as new lines arrive instead of replacing the
/// whole text on every update, so a long sync doesn't repeatedly rebuild the text storage.
struct IDEGradleConsoleView: NSViewRepresentable {
    let log: IDEGradleConsoleLog
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
        textView.insertionPointColor = IDEAppearance.NSToken.foreground
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
        /// How many lines of the run the text has been given, dropped ones included, so the next
        /// line to draw is number `renderedTotal`. A count of lines *in the log* would stall once the
        /// log is full: it stays at `maxLines` while old lines fall off the front.
        private var renderedTotal = 0
        /// Character counts of the lines in the text, oldest first; `lengths.last` is line
        /// `renderedTotal - 1`.
        private var lengths: [Int] = []
        /// Characters of the "earlier lines not shown" notice at the top of the text, or 0.
        private var noticeLength = 0
        private var noticeCount = 0

        func render(_ log: IDEGradleConsoleLog, fontName: String, fontSize: Double, fullReplace: Bool) {
            guard let textView, let textStorage = textView.textStorage else { return }
            let font = IDEEditorFonts.nsFont(familyName: fontName, size: CGFloat(fontSize))
            let wasAtBottom = isScrolledToBottom(textView)

            if fullReplace {
                textStorage.setAttributedString(NSAttributedString(string: ""))
                lengths = []
                noticeLength = 0
                noticeCount = 0
                renderedTotal = log.droppedCount
                lastRunID = log.runID
                lastFontName = fontName
                lastFontSize = fontSize
            }

            // Text for lines the log has since dropped goes; a line dropped before it was ever drawn is skipped.
            let firstRendered = renderedTotal - lengths.count
            if log.droppedCount > firstRendered {
                let drop = min(log.droppedCount - firstRendered, lengths.count)
                if drop > 0 {
                    let characters = lengths.prefix(drop).reduce(0, +)
                    textStorage.deleteCharacters(in: NSRange(location: noticeLength, length: characters))
                    lengths.removeFirst(drop)
                }
                renderedTotal = max(renderedTotal, log.droppedCount)
            }

            let start = renderedTotal - log.droppedCount
            if start < log.lines.count {
                let appended = NSMutableAttributedString()
                for line in log.lines[start...] {
                    let text = line.text + "\n"
                    appended.append(Self.attributedString(for: text, line: line, font: font))
                    lengths.append((text as NSString).length)
                }
                textStorage.append(appended)
                renderedTotal = log.totalLineCount
            }

            if log.droppedCount != noticeCount {
                let notice = log.droppedCount > 0
                    ? NSAttributedString(
                        string: "… \(log.droppedCount) earlier line\(log.droppedCount == 1 ? "" : "s") not shown\n",
                        attributes: [.font: font, .foregroundColor: IDEAppearance.NSToken.muted]
                    )
                    : NSAttributedString(string: "")
                textStorage.replaceCharacters(in: NSRange(location: 0, length: noticeLength), with: notice)
                noticeLength = notice.length
                noticeCount = log.droppedCount
            }

            if wasAtBottom {
                textView.scrollToEndOfDocument(nil)
            }
        }

        /// Only auto-scroll while the reader hasn't scrolled up to look at earlier output --
        /// otherwise a fast-moving sync would yank the viewport back to the bottom mid-read.
        private func isScrolledToBottom(_ textView: NSTextView) -> Bool {
            guard let scrollView = textView.enclosingScrollView else { return true }
            let visibleMaxY = scrollView.contentView.bounds.maxY
            let documentHeight = scrollView.documentView?.bounds.height ?? 0
            return documentHeight - visibleMaxY < 24
        }

        private static func attributedString(for text: String, line: IDEGradleConsoleLog.Line, font: NSFont) -> NSAttributedString {
            let color: NSColor
            switch line {
            case .process(let processLine):
                color = processLine.stream == .stderr ? IDEAppearance.NSToken.error : IDEAppearance.NSToken.foreground
            case .note:
                color = IDEAppearance.NSToken.muted
            }
            return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        }
    }
}
