import Foundation

/// A "surround with" template (⌥⌘T): wraps the current selection in some construct — an `if`
/// block, a `try`/`catch`, brackets, quotes.
///
/// ``body`` is a TextMate-style snippet. The selection is substituted for `$TM_SELECTED_TEXT`
/// (or `${TM_SELECTED_TEXT}`); `$0` marks where the caret lands afterwards. Expansion is done
/// with `EditorIntelligence`'s `SnippetParser` / `SnippetExpander`.
public struct SurroundTemplate: Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let body: String
    /// Language identifiers this template applies to (see ``LanguageIdentifier``). `nil` means
    /// every language — used for the universal bracket/quote wrappers.
    public let languages: Set<String>?

    public init(id: String, title: String, body: String, languages: Set<String>? = nil) {
        self.id = id
        self.title = title
        self.body = body
        self.languages = languages
    }

    /// Whether this template should be offered for `languageIdentifier` (`nil` identifier =
    /// only the universal templates apply).
    public func applies(to languageIdentifier: String?) -> Bool {
        guard let languages else { return true }
        guard let languageIdentifier else { return false }
        return languages.contains(languageIdentifier)
    }
}

public extension SurroundTemplate {
    /// Universal wrappers plus a set of C-family block templates. Assign your own list to
    /// ``TextView/surroundTemplates`` to change what ⌥⌘T offers.
    static let builtIns: [SurroundTemplate] = universal + cFamily + pythonFamily

    static let universal: [SurroundTemplate] = [
        SurroundTemplate(id: "parentheses", title: "( … )", body: "(${TM_SELECTED_TEXT})$0"),
        SurroundTemplate(id: "brackets", title: "[ … ]", body: "[${TM_SELECTED_TEXT}]$0"),
        SurroundTemplate(id: "braces", title: "{ … }", body: "{${TM_SELECTED_TEXT}}$0"),
        SurroundTemplate(id: "doubleQuotes", title: "\" … \"", body: "\"${TM_SELECTED_TEXT}\"$0"),
        SurroundTemplate(id: "singleQuotes", title: "' … '", body: "'${TM_SELECTED_TEXT}'$0"),
        SurroundTemplate(id: "backticks", title: "` … `", body: "`${TM_SELECTED_TEXT}`$0")
    ]

    private static let cFamilyLanguages: Set<String> = [
        "swift", "java", "kotlin", "c", "cpp", "objc", "objcpp", "csharp",
        "javascript", "typescript", "jsx", "tsx", "go", "rust", "php", "scala", "dart"
    ]

    static let cFamily: [SurroundTemplate] = [
        SurroundTemplate(id: "if", title: "if ( … ) { … }",
                         body: "if (${1:condition}) {\n\t${TM_SELECTED_TEXT}\n}$0",
                         languages: cFamilyLanguages),
        SurroundTemplate(id: "while", title: "while ( … ) { … }",
                         body: "while (${1:condition}) {\n\t${TM_SELECTED_TEXT}\n}$0",
                         languages: cFamilyLanguages),
        SurroundTemplate(id: "for", title: "for ( … ) { … }",
                         body: "for (${1:item}) {\n\t${TM_SELECTED_TEXT}\n}$0",
                         languages: cFamilyLanguages),
        SurroundTemplate(id: "tryCatch", title: "try { … } catch { … }",
                         body: "try {\n\t${TM_SELECTED_TEXT}\n} catch (${1:error}) {\n\t$0\n}",
                         languages: cFamilyLanguages),
        SurroundTemplate(id: "block", title: "{ … }", body: "{\n\t${TM_SELECTED_TEXT}\n}$0",
                         languages: cFamilyLanguages)
    ]

    static let pythonFamily: [SurroundTemplate] = [
        SurroundTemplate(id: "pyIf", title: "if …:", body: "if ${1:condition}:\n\t${TM_SELECTED_TEXT}$0",
                         languages: ["python"]),
        SurroundTemplate(id: "pyWhile", title: "while …:", body: "while ${1:condition}:\n\t${TM_SELECTED_TEXT}$0",
                         languages: ["python"]),
        SurroundTemplate(id: "pyTry", title: "try: … except:",
                         body: "try:\n\t${TM_SELECTED_TEXT}\nexcept ${1:Exception}:\n\t$0",
                         languages: ["python"])
    ]
}
