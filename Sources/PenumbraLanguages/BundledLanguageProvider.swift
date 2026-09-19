import Penumbra

/// Resolves injected-language names used by the bundled HTML and JavaScript queries
/// (`"javascript"`, `"css"`, tagged-template names that match a bundled identifier).
public final class BundledLanguageProvider: TreeSitterLanguageProvider, @unchecked Sendable {
    public init() {}

    public func treeSitterLanguage(named languageName: String) -> TreeSitterLanguage? {
        // HTML/JS queries emit canonical names, but markdown fences carry whatever the author typed
        // (```js, ```Swift, ```yml). Canonical names pass through `normalize` unchanged.
        BundledLanguages.language(forIdentifier: FenceLanguageName.normalize(languageName) ?? languageName)
    }
}

/// Resolves `<script>` → JavaScript and `<style>` → CSS for ``TreeSitterLanguage/html``.
public final class HTMLLanguageProvider: TreeSitterLanguageProvider, @unchecked Sendable {
    public init() {}

    public func treeSitterLanguage(named languageName: String) -> TreeSitterLanguage? {
        switch languageName {
        case "javascript", "js":
            return .javaScript
        case "css":
            return .css
        default:
            return nil
        }
    }
}
