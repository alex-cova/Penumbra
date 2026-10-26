import AppKit
import SwiftUI

/// Laid over the editor while a profile tab is selected, as the diagram viewer is.
@MainActor
final class IDEProfilerViewerView: NSView {
    private(set) var session: IDEProfilerSession?
    private var hosting: NSHostingView<IDEProfilerView>?

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

    func show(_ session: IDEProfilerSession) {
        isHidden = false
        layer?.backgroundColor = IDEAppearance.NSToken.editor.cgColor
        let isNew = session !== self.session || hosting == nil
        self.session = session
        install(session)
        if isNew, session.phase == .idle { session.load() }
    }

    func hide() {
        isHidden = true
    }

    func detach(_ closing: IDEProfilerSession) {
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

    private func install(_ session: IDEProfilerSession) {
        let root = IDEProfilerView(session: session)
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
