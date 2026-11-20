import AppKit
import SwiftUI

/// The console of one run: its output as it arrives, errors in red, typed input in the accent
/// colour, and the `at pkg.Class.method(File.java:12)` lines of a stack trace as links that open the
/// source. Draws incrementally by chunk number, like `IDEProjectConsoleView`.
struct IDERunConsoleView: NSViewRepresentable {
    let log: IDERunConsoleLog
    let fontName: String
    let fontSize: Double
    let onOpenFrame: (IDEStackFrameReference) -> Void
    /// A heap dump path the JVM printed ("Dumping heap to …"), as printed: relative to the run's folder.
    var onOpenHeapDump: (String) -> Void = { _ in }
    /// Bumped by "Scroll to End" so the view jumps to the bottom even after the reader scrolled up.
    var scrollToEndRequest = 0

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
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.linkTextAttributes = [
            .foregroundColor: IDEAppearance.NSToken.accent,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand
        ]
        textView.delegate = context.coordinator
        scrollView.documentView = textView

        context.coordinator.textView = textView
        context.coordinator.onOpenFrame = onOpenFrame
        context.coordinator.onOpenHeapDump = onOpenHeapDump
        context.coordinator.render(log, fontName: fontName, fontSize: fontSize, fullReplace: true)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onOpenFrame = onOpenFrame
        coordinator.onOpenHeapDump = onOpenHeapDump
        let fullReplace = coordinator.lastGeneration != log.generation
            || coordinator.lastFontName != fontName
            || coordinator.lastFontSize != fontSize
        coordinator.render(log, fontName: fontName, fontSize: fontSize, fullReplace: fullReplace)
        if coordinator.lastScrollRequest != scrollToEndRequest {
            coordinator.lastScrollRequest = scrollToEndRequest
            coordinator.textView?.scrollToEndOfDocument(nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: NSTextView?
        var onOpenFrame: (IDEStackFrameReference) -> Void = { _ in }
        var onOpenHeapDump: (String) -> Void = { _ in }
        var lastGeneration: UUID?
        var lastFontName: String?
        var lastFontSize: Double?
        var lastScrollRequest = 0
        /// Chunks given to the text so far, dropped ones included.
        private var renderedTotal = 0
        /// UTF-16 length of each chunk in the text, oldest first.
        private var lengths: [Int] = []
        private var noticeLength = 0
        private var noticeCount = 0

        func render(_ log: IDERunConsoleLog, fontName: String, fontSize: Double, fullReplace: Bool) {
            guard let textView, let storage = textView.textStorage else { return }
            let font = IDEEditorFonts.nsFont(familyName: fontName, size: CGFloat(fontSize))
            let wasAtBottom = isScrolledToBottom(textView)

            if fullReplace {
                storage.setAttributedString(NSAttributedString(string: ""))
                lengths = []
                noticeLength = 0
                noticeCount = 0
                renderedTotal = log.droppedCount
                lastGeneration = log.generation
                lastFontName = fontName
                lastFontSize = fontSize
            }

            let firstRendered = renderedTotal - lengths.count
            if log.droppedCount > firstRendered {
                let drop = min(log.droppedCount - firstRendered, lengths.count)
                if drop > 0 {
                    let characters = lengths.prefix(drop).reduce(0, +)
                    storage.deleteCharacters(in: NSRange(location: noticeLength, length: characters))
                    lengths.removeFirst(drop)
                }
                renderedTotal = max(renderedTotal, log.droppedCount)
            }

            let start = renderedTotal - log.droppedCount
            if start < log.segments.count {
                let appended = NSMutableAttributedString()
                for segment in log.segments[start...] {
                    let piece = Self.attributed(segment, font: font)
                    appended.append(piece)
                    lengths.append(piece.length)
                }
                storage.append(appended)
                renderedTotal = log.totalCount
            }

            if log.droppedCount != noticeCount {
                let notice = log.droppedCount > 0
                    ? NSAttributedString(
                        string: "… earlier output not shown\n",
                        attributes: [.font: font, .foregroundColor: IDEAppearance.NSToken.muted]
                    )
                    : NSAttributedString(string: "")
                storage.replaceCharacters(in: NSRange(location: 0, length: noticeLength), with: notice)
                noticeLength = notice.length
                noticeCount = log.droppedCount
            }

            if wasAtBottom { textView.scrollToEndOfDocument(nil) }
        }

        /// Follow the output only while the reader has not scrolled up to look at something.
        private func isScrolledToBottom(_ textView: NSTextView) -> Bool {
            guard let scrollView = textView.enclosingScrollView else { return true }
            let visibleMaxY = scrollView.contentView.bounds.maxY
            let documentHeight = scrollView.documentView?.bounds.height ?? 0
            return documentHeight - visibleMaxY < 24
        }

        private static func attributed(_ segment: IDERunConsoleLog.Segment, font: NSFont) -> NSAttributedString {
            let color: NSColor
            switch segment.stream {
            case .stdout: color = IDEAppearance.NSToken.foreground
            case .stderr: color = IDEAppearance.NSToken.error
            case .input: color = IDEAppearance.NSToken.accent
            case .note: color = IDEAppearance.NSToken.muted
            }
            let result = NSMutableAttributedString(
                string: segment.text, attributes: [.font: font, .foregroundColor: color]
            )
            guard segment.stream == .stdout || segment.stream == .stderr else { return result }
            linkHeapDumps(in: segment.text, into: result)
            guard segment.text.contains("(") else { return result }
            let text = segment.text as NSString
            var lineStart = 0
            while lineStart < text.length {
                let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))
                let line = text.substring(with: lineRange)
                if line.contains(".java:") || line.contains(".kt:") || line.contains(".groovy:"),
                   let frame = IDEStackFrameReference.parse(line), let url = frameURL(frame) {
                    // Link the `File.java:12` part, as an IDE does, not the whole line.
                    let location = "\(frame.fileName):\(frame.line)"
                    let found = (line as NSString).range(of: location)
                    if found.location != NSNotFound {
                        result.addAttribute(
                            .link, value: url,
                            range: NSRange(location: lineRange.location + found.location, length: found.length)
                        )
                    }
                }
                lineStart = NSMaxRange(lineRange)
            }
            return result
        }

        /// HotSpot's `Dumping heap to java_pid123.hprof ...` (HeapDumpOnOutOfMemoryError): the path
        /// becomes a link that opens the dump.
        static func linkHeapDumps(in text: String, into result: NSMutableAttributedString) {
            guard text.contains("Dumping heap to ") else { return }
            let string = text as NSString
            var lineStart = 0
            while lineStart < string.length {
                let lineRange = string.lineRange(for: NSRange(location: lineStart, length: 0))
                let line = string.substring(with: lineRange)
                if let path = heapDumpPath(inLine: line) {
                    let found = (line as NSString).range(of: path)
                    var components = URLComponents()
                    components.scheme = "umbra-heapdump"
                    components.host = "open"
                    components.queryItems = [URLQueryItem(name: "path", value: path)]
                    if found.location != NSNotFound, let url = components.url {
                        result.addAttribute(.link, value: url, range: NSRange(location: lineRange.location + found.location, length: found.length))
                    }
                }
                lineStart = NSMaxRange(lineRange)
            }
        }

        /// The path in `Dumping heap to <path> ...`, or nil.
        static func heapDumpPath(inLine line: String) -> String? {
            guard let start = line.range(of: "Dumping heap to ") else { return nil }
            var path = line[start.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if path.hasSuffix("...") { path = String(path.dropLast(3)).trimmingCharacters(in: .whitespaces) }
            return path.isEmpty ? nil : path
        }

        static func frameURL(_ frame: IDEStackFrameReference) -> URL? {
            var components = URLComponents()
            components.scheme = "umbra-frame"
            components.host = "open"
            components.queryItems = [
                URLQueryItem(name: "class", value: frame.className),
                URLQueryItem(name: "file", value: frame.fileName),
                URLQueryItem(name: "line", value: String(frame.line))
            ]
            return components.url
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL, url.scheme == "umbra-heapdump",
               let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "path" })?.value {
                onOpenHeapDump(path)
                return true
            }
            guard let url = link as? URL, url.scheme == "umbra-frame",
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                  let className = items.first(where: { $0.name == "class" })?.value,
                  let file = items.first(where: { $0.name == "file" })?.value,
                  let line = items.first(where: { $0.name == "line" })?.value.flatMap(Int.init) else { return false }
            onOpenFrame(IDEStackFrameReference(className: className, fileName: file, line: line))
            return true
        }
    }
}
