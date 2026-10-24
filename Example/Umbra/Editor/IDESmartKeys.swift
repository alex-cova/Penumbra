import Penumbra

/// What the Smart Keys settings turn on for one language: which characters are paired as they are
/// typed, whether Enter closes an open brace, and the markup tag helpers.
///
/// Pure, so the per-language tables are tested without a text view. `IDEPreferences.applySmartKeys`
/// copies the result onto an editor.
struct IDESmartKeysConfiguration: Equatable {
    var characterPairs: [BasicCharacterPair] = []
    var insertsClosingBraceOnEnter = false
    var tagAutoClosing: TagAutoClosingOptions = []
    var voidTagNames: Set<String>?

    struct Switches: Equatable {
        var insertPairedBrackets = true
        var insertPairedQuotes = true
        var insertClosingBraceOnEnter = true
        var insertClosingTagOnTagCompletion = true
        var autoCloseTagOnSlash = true
    }

    /// Languages with no pairing at all: prose, tabular data and diffs.
    private static let unpaired: Set<String> = ["plain", "csv", "tsv", "diff", "gitignore"]
    /// Languages whose `<` opens generic arguments after a type name.
    private static let genericAngle: Set<String> = [
        "java", "kotlin", "swift", "typescript", "tsx", "rust", "csharp", "cpp"
    ]
    /// Languages that also pair a backtick (template strings, code spans, raw strings, command substitution).
    private static let backtick: Set<String> = [
        "javascript", "typescript", "jsx", "tsx", "go", "shell", "markdown"
    ]
    /// Languages where a single quote is not a delimiter pair (`'a` is a lifetime) or is prose.
    private static let noSingleQuote: Set<String> = ["rust", "markdown"]
    /// Languages written with braces, where Enter after an unclosed `{` adds the `}`.
    private static let braced: Set<String> = [
        "java", "kotlin", "groovy", "javascript", "typescript", "jsx", "tsx", "swift", "rust", "go",
        "c", "cpp", "csharp", "css", "scss", "json", "graphql"
    ]

    static func make(language: String?, switches: Switches = Switches()) -> IDESmartKeysConfiguration {
        guard let language, !unpaired.contains(language) else {
            return IDESmartKeysConfiguration()
        }
        var configuration = IDESmartKeysConfiguration()
        let isMarkup = language == "html" || language == "xml"

        if switches.insertPairedBrackets {
            configuration.characterPairs += [
                BasicCharacterPair(leading: "(", trailing: ")", kind: .bracket),
                BasicCharacterPair(leading: "[", trailing: "]", kind: .bracket),
                BasicCharacterPair(leading: "{", trailing: "}", kind: .bracket)
            ]
            if genericAngle.contains(language) {
                configuration.characterPairs.append(BasicCharacterPair(leading: "<", trailing: ">", kind: .genericAngle))
            }
        }
        if switches.insertPairedQuotes {
            if language != "markdown" {
                configuration.characterPairs.append(BasicCharacterPair(leading: "\"", trailing: "\"", kind: .quote))
            }
            if !noSingleQuote.contains(language) {
                configuration.characterPairs.append(BasicCharacterPair(leading: "'", trailing: "'", kind: .quote))
            }
            if backtick.contains(language) {
                configuration.characterPairs.append(BasicCharacterPair(leading: "`", trailing: "`", kind: .quote))
            }
        }
        configuration.insertsClosingBraceOnEnter = switches.insertClosingBraceOnEnter && braced.contains(language)
        if isMarkup {
            var options: TagAutoClosingOptions = []
            if switches.insertClosingTagOnTagCompletion {
                options.insert(.onStartTagCompletion)
            }
            if switches.autoCloseTagOnSlash {
                options.insert(.onEndTagSlash)
            }
            configuration.tagAutoClosing = options
            configuration.voidTagNames = language == "html" ? TagAutoClosingOptions.htmlVoidTagNames : nil
        }
        return configuration
    }
}
