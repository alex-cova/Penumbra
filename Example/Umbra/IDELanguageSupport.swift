import Runestone
import RunestoneLanguages
import RunestoneMarkdownLanguage

enum IDELanguageSupport {
    private static let languageCache = TreeSitterLanguageCache<String>()

    static func language(forIdentifier identifier: String?) -> TreeSitterLanguage? {
        guard let identifier else { return nil }
        return languageCache.language(for: identifier) {
            if identifier == "markdown" {
                return .markdown
            }
            if let bundled = TreeSitterLanguage.bundled(forIdentifier: identifier) {
                return bundled
            }
            switch identifier {
            case "java":
                return .java
            case "go":
                return .go
            case "kotlin":
                return .kotlin
            case "bash":
                return .bash
            case "sql":
                return .sql
            case "toml":
                return .toml
            case "graphql":
                return .graphQL
            default:
                return nil
            }
        }
    }

    static func languageResolver(snapshot: WorkbenchDocumentSnapshot) -> TreeSitterLanguage? {
        language(forIdentifier: snapshot.languageIdentifier)
    }

    static func fileBackedLanguageResolver(document: WorkbenchDocument) -> TreeSitterLanguage? {
        language(forIdentifier: document.languageIdentifier)
    }
}
