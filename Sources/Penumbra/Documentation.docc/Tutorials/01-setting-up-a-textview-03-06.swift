import Penumbra
import AppKit

final class EditorViewController: NSViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let textView = TextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.editorDelegate = self
        textView.backgroundColor = .windowBackgroundColor
        setCustomization(on: textView)
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.topAnchor.constraint(equalTo: view.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func setCustomization(on textView: TextView) {
        // ...
    }
}

extension ViewController: TextViewDelegate {
    
}
