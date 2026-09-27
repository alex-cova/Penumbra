import Penumbra
import AppKit

class ViewController: NSViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "TextCompanion"
        let textView = TextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.backgroundColor = .systemBackground
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
        textView.textContainerInset = NSEdgeInsets(top: 8, left: 5, bottom: 8, right: 5)
        textView.showLineNumbers = true
        textView.lineHeightMultiplier = 1.2
    }
}
