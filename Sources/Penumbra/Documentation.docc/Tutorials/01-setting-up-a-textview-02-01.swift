import Penumbra
import AppKit

final class EditorViewController: NSViewController {
    private let textView = TextView()

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.backgroundColor = .windowBackgroundColor
        container.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            textView.topAnchor.constraint(equalTo: container.topAnchor),
            textView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        view = container
    }
}
