import Foundation
import Penumbra

/// The look the user gave the Markdown preview with its sun/moon button. Kept on this Mac, for
/// every window; absent means the preview follows the editor theme. It affects the on-screen
/// preview only: PDF export is always light.
enum IDEMarkdownPreviewAppearance {
    static let defaultsKey = "umbra.markdown.previewAppearance"

    static var stored: MarkdownPreviewAppearance? {
        get {
            UserDefaults.standard.string(forKey: defaultsKey).flatMap(MarkdownPreviewAppearance.init(rawValue:))
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }
    }
}
