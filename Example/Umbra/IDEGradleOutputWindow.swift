import AppKit

/// One reusable panel for the last Gradle project-model run. There is no shared output console
/// (the terminal host always spawns a shell), so this is a plain read-only text view.
@MainActor
final class IDEGradleOutputPanel {
    static let shared = IDEGradleOutputPanel()

    private var panel: NSPanel?
    private var textView: NSTextView?

    private init() {}

    func show(_ text: String) {
        let panel = ensurePanel()
        textView?.string = text
        textView?.scrollToBeginningOfDocument(nil)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Gradle Output"
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 480, height: 280)
        panel.center()

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = IDEAppearance.NSToken.editor
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = IDEAppearance.NSToken.editor
        textView.textColor = IDEAppearance.NSToken.foreground
        textView.insertionPointColor = IDEAppearance.NSToken.foreground
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView

        panel.contentView = NSView()
        panel.contentView?.addSubview(scrollView)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([
                scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                scrollView.topAnchor.constraint(equalTo: content.topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor)
            ])
        }

        self.panel = panel
        self.textView = textView
        return panel
    }
}
