import Foundation

/// The preview shares ``FenceLanguageName``'s alias table with the editor's fence injection.
enum MarkdownPreviewFenceLanguage {
    static func normalize(_ hint: String?) -> String? {
        FenceLanguageName.normalize(hint)
    }
}
