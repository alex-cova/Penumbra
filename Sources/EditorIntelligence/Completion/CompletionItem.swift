import Foundation

/// Classification of a completion item.
public enum CompletionItemKind: Hashable, Sendable, CustomStringConvertible {
    case text
    case keyword
    case function
    case method
    case constructor
    case property
    case field
    case variable
    case enumMember
    case type
    case `class`
    case interface
    case `enum`
    case annotation
    case snippet
    case module
    case package
    case file
    case command

    public var description: String {
        switch self {
        case .text: return "text"
        case .keyword: return "keyword"
        case .function: return "function"
        case .method: return "method"
        case .constructor: return "constructor"
        case .property: return "property"
        case .field: return "field"
        case .variable: return "variable"
        case .enumMember: return "enumMember"
        case .type: return "type"
        case .class: return "class"
        case .interface: return "interface"
        case .enum: return "enum"
        case .annotation: return "annotation"
        case .snippet: return "snippet"
        case .module: return "module"
        case .package: return "package"
        case .file: return "file"
        case .command: return "command"
        }
    }

    /// Whether this kind names a type (class, interface, enum, annotation, or a generic type).
    public var isTypeLike: Bool {
        switch self {
        case .type, .class, .interface, .enum, .annotation: return true
        default: return false
        }
    }
}

/// What accepting a command completion item does.
public enum CompletionCommand: Hashable, Sendable {
    /// Runs an editor action by its `EditorActionID` raw value, first selecting `selecting` when set.
    case editorAction(id: String, selecting: TextRange?)
    /// Applies a code action's edits (and its host command, if any).
    case codeAction(CodeAction)
}

/// A section of the completion list. Only commands use one today; they always sort last.
public enum CompletionSection: Hashable, Sendable {
    case commands

    public var title: String { "Commands" }
}

/// A single completion suggestion produced by a provider and later ranked by the completion engine.
public struct CompletionItem: Hashable, Sendable, Identifiable, CustomStringConvertible {
    public let id: UUID
    public let label: String
    public let insertText: String
    public let kind: CompletionItemKind
    public let range: TextRange
    public let source: String
    public let documentation: String?
    public let sortText: String?
    public let filterText: String?
    /// Right-aligned type text: a field's type, a method's return type, a class's package.
    public let detail: String?
    /// Dimmed text drawn right after the label, e.g. a method's `(String s, int i)`.
    public let labelDetail: String?
    public let isDeprecated: Bool
    /// `insertText` uses TextMate snippet syntax (tab stops, placeholders). Items of kind
    /// ``CompletionItemKind/snippet`` are always treated as snippets.
    public let insertTextIsSnippet: Bool
    /// Edits applied alongside the main insertion in one undo step, e.g. an auto-import.
    public let additionalEdits: [TextEdit]
    /// Provider-assigned relevance within a match tier; 0 is neutral, higher ranks first.
    public let priority: Double
    /// Where the caret lands, as a UTF-16 offset into `insertText`; `nil` means after it.
    public let caretOffset: Int?
    /// Accepting this item should open parameter info (a method with parameters).
    public let triggersSignatureHelp: Bool
    /// Complete Current Statement, after accepting this item, appends `;` but leaves the caret
    /// between the parentheses. Set for a method or constructor that inserted `()` around parameters.
    public let statementCaretInsideParens: Bool
    /// Selected by default when the popup opens, e.g. an expected-type match.
    public let preselect: Bool
    /// A lone explicit completion may insert this item immediately. Class names, chains, and
    /// generated templates stay in the popup.
    public let allowsAutoInsert: Bool
    /// The type a member is inherited from, drawn dimmed after the label (`getSpecies() Animal`);
    /// `nil` for members of the receiver's own type and for everything that isn't a member.
    public let origin: String?
    /// Set for `kind == .command` items: the action to run instead of inserting text.
    public let command: CompletionCommand?
    /// The list section this item belongs to, if any.
    public let section: CompletionSection?

    public init(
        id: UUID = UUID(),
        label: String,
        insertText: String,
        kind: CompletionItemKind,
        range: TextRange,
        source: String,
        documentation: String? = nil,
        sortText: String? = nil,
        filterText: String? = nil,
        detail: String? = nil,
        labelDetail: String? = nil,
        isDeprecated: Bool = false,
        insertTextIsSnippet: Bool = false,
        additionalEdits: [TextEdit] = [],
        priority: Double = 0,
        caretOffset: Int? = nil,
        triggersSignatureHelp: Bool = false,
        statementCaretInsideParens: Bool = false,
        preselect: Bool = false,
        allowsAutoInsert: Bool = true,
        origin: String? = nil,
        command: CompletionCommand? = nil,
        section: CompletionSection? = nil
    ) {
        self.id = id
        self.label = label
        self.insertText = insertText
        self.kind = kind
        self.range = range
        self.source = source
        self.documentation = documentation
        self.sortText = sortText
        self.filterText = filterText
        self.detail = detail
        self.labelDetail = labelDetail
        self.isDeprecated = isDeprecated
        self.insertTextIsSnippet = insertTextIsSnippet
        self.additionalEdits = additionalEdits
        self.priority = priority
        self.caretOffset = caretOffset
        self.triggersSignatureHelp = triggersSignatureHelp
        self.statementCaretInsideParens = statementCaretInsideParens
        self.preselect = preselect
        self.allowsAutoInsert = allowsAutoInsert
        self.origin = origin
        self.command = command
        self.section = section
    }

    /// Whether `insertText` must be expanded as a snippet.
    public var isSnippet: Bool {
        insertTextIsSnippet || kind == .snippet
    }

    /// The text matched against the typed prefix.
    public var matchText: String {
        filterText ?? label
    }

    /// Identity used to merge duplicates across providers and to keep the selection across
    /// re-filtering: overloads differ in `labelDetail`, so they stay distinct.
    public var identityKey: String {
        "\(label)|\(insertText)|\(labelDetail ?? "")|\(detail ?? "")"
    }

    public var description: String {
        "\(label) [\(kind)] from \(source)"
    }
}
