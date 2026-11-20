import AppKit
import SwiftUI

/// Laid over the editor while a heap dump tab is selected, as the profile viewer is.
@MainActor
final class IDEHeapDumpViewerView: NSView {
    private(set) var session: IDEHeapDumpSession?
    private var hosting: NSHostingView<IDEHeapDumpView>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = IDEAppearance.NSToken.editor.cgColor
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Shows `session`, reading its dump the first time it is shown.
    func show(_ session: IDEHeapDumpSession) {
        isHidden = false
        layer?.backgroundColor = IDEAppearance.NSToken.editor.cgColor
        self.session = session
        install(session)
        if session.phase == .idle { session.load() }
    }

    func hide() {
        isHidden = true
    }

    func detach(_ closing: IDEHeapDumpSession) {
        guard closing === session else { return }
        closing.cancel()
        hosting?.removeFromSuperview()
        hosting = nil
        session = nil
        isHidden = true
    }

    func focus() {
        guard let hosting else { return }
        window?.makeFirstResponder(hosting)
    }

    private func install(_ session: IDEHeapDumpSession) {
        let root = IDEHeapDumpView(session: session)
        if let hosting {
            hosting.rootView = root
            return
        }
        let host = NSHostingView(rootView: root)
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        hosting = host
    }
}
