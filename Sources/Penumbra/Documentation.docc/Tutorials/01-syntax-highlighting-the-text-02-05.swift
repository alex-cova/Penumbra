import Penumbra
import TreeSitterJavaScriptPenumbra
import AppKit

final class EditorViewController: NSViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let textView = TextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.editorDelegate = self
        textView.backgroundColor = .windowBackgroundColor
        setCustomization(on: textView)
        setTextViewState(on: textView)
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

    private func setTextViewState(on textView: TextView) {
        DispatchQueue.global(qos: .userInitiated).async {
            let text = UserDefaults.standard.text
            let state = TextViewState(text: text, language: .javaScript)
        }
    }
}

extension ViewController: TextViewDelegate {
    func textViewDidChange(_ textView: TextView) {
        UserDefaults.standard.text = textView.text
    }
}
