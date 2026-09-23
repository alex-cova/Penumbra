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
        private var renderedLineCount = 0

        func render(_ log: IDEGradleConsoleLog, fontName: String, fontSize: Double, fullReplace: Bool) {
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
            let appended = NSMutableAttributedString()
            for line in newLines {
                if appended.length > 0 || textStorage.length > 0 {
                    appended.append(NSAttributedString(string: "\n"))
                }
                appended.append(Self.attributedString(for: line, font: font))
            }
            textStorage.append(appended)
            renderedLineCount = log.lines.count

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

        private static func attributedString(for line: IDEGradleConsoleLog.Line, font: NSFont) -> NSAttributedString {
            let color: NSColor
            switch line {
            case .process(let processLine):
                color = processLine.stream == .stderr ? IDEAppearance.NSToken.error : IDEAppearance.NSToken.foreground
            case .note:
                color = IDEAppearance.NSToken.muted
            }
            return NSAttributedString(string: line.text, attributes: [.font: font, .foregroundColor: color])
        }
    }
}
