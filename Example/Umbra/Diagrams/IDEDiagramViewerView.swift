import AppKit
import SwiftUI

/// The diagram tab's content, laid over the pane's editor while a diagram tab is selected.
@MainActor
final class IDEDiagramViewerView: NSView {
    private(set) var session: IDEDiagramSession?
    private var hosting: NSHostingView<IDEDiagramRootView>?

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

    func show(_ session: IDEDiagramSession) {
        isHidden = false
        layer?.backgroundColor = IDEAppearance.NSToken.editor.cgColor
        guard session !== self.session || hosting == nil else {
            install(session)
            return
        }
        self.session = session
        install(session)
        if session.state == .loading, session.document.nodes.isEmpty, session.loadedAt == nil {
            session.reload()
        }
    }

    func hide() {
        isHidden = true
    }

    func detach(_ closing: IDEDiagramSession) {
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

    /// Rebuilt on every show so a changed UI color scheme is picked up.
    private func install(_ session: IDEDiagramSession) {
        let root = IDEDiagramRootView(session: session, window: { [weak self] in self?.window })
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
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        hosting = host
    }
}
