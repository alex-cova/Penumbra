import Runestone
import RunestoneLanguages

enum IDELanguageSupport {
    static func language(forIdentifier identifier: String?) -> TreeSitterLanguage? {
        BundledLanguages.language(forIdentifier: identifier)
    }

    static func languageResolver(snapshot: WorkbenchDocumentSnapshot) -> TreeSitterLanguage? {
        language(forIdentifier: snapshot.languageIdentifier)
    }

    static func fileBackedLanguageResolver(document: WorkbenchDocument) -> TreeSitterLanguage? {
        language(forIdentifier: document.languageIdentifier)
    }
}
