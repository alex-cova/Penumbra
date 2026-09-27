import AppKit

final class EditorViewController: NSViewController {
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
    }
}
