import AppKit
import SwiftUI

/// The hex tab's content, laid over the pane's editor while a hex tab is selected.
@MainActor
final class IDEHexViewerView: NSView {
    private(set) var session: IDEHexSession?
    private var hosting: NSHostingView<IDEHexRootView>?

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

    func show(_ session: IDEHexSession) {
        isHidden = false
        layer?.backgroundColor = IDEAppearance.NSToken.editor.cgColor
        self.session = session
        let root = IDEHexRootView(session: session)
        if let hosting {
            hosting.rootView = root
        } else {
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

    func hide() {
        isHidden = true
    }

    func detach(_ closing: IDEHexSession) {
        guard closing === session else { return }
        hosting?.removeFromSuperview()
        hosting = nil
        session = nil
        isHidden = true
    }

    func focus() {
        guard let hosting else { return }
        window?.makeFirstResponder(hosting)
    }
}
