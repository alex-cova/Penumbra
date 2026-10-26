import EditorIntelligence
import Foundation

/// `@` in a Markdown file offers the project's files, so a prompt written in the editor can name them
/// the way the Agent chat does. Accepting a row inserts the project-relative path (quoted when it has
/// whitespace); the Agent resolves it when the file is run with it.
///
/// The popup's prefix covers identifier characters only, so the user types a file name fragment
/// (`@Main`), not a path.
final class MarkdownFileMentionCompletionProvider: CompletionProvider, @unchecked Sendable {
    typealias FileSource = @Sendable (_ query: String, _ limit: Int) async -> [String]

    static let limit = 30

    let name = "Markdown File Mention"

    private let lock = NSLock()
    private var source: FileSource?

    init(source: FileSource? = nil) {
        self.source = source
    }

    func setSource(_ source: FileSource?) {
        lock.lock()
        defer { lock.unlock() }
        self.source = source
    }

    private var currentSource: FileSource? {
        lock.lock()
        defer { lock.unlock() }
        return source
    }

    func isPrimary(for context: CompletionContext) -> Bool {
        Self.isMention(context)
    }

    func provide(context: CompletionContext) async -> [CompletionItem] {
        guard Self.isMention(context), let source = currentSource else { return [] }
        let paths = await source(context.prefix, Self.limit)
        guard !Task.isCancelled else { return [] }
        return paths.prefix(Self.limit).map { path in
            let fileName = (path as NSString).lastPathComponent
            let folder = (path as NSString).deletingLastPathComponent
            return CompletionItem(
                label: fileName,
                insertText: Self.insertion(for: path),
                kind: .file,
                range: context.range,
                source: name,
                filterText: fileName,
                detail: folder.isEmpty ? nil : folder)
        }
    }

    /// What follows the `@`: the path, or the quoted form when it has whitespace.
    static func insertion(for path: String) -> String {
        path.rangeOfCharacter(from: .whitespacesAndNewlines) == nil ? path : "\"" + path + "\""
    }

    /// A Markdown document whose prefix directly follows an `@` that starts a word, so `me@example.com`
    /// is left alone (the same rule the Agent's `@` mentions use).
    static func isMention(_ context: CompletionContext) -> Bool {
        guard context.document.languageIdentifier == "markdown" else { return false }
        let start = context.range.start.utf16Offset
        guard start > 0, context.document.substring(utf16Offset: start - 1, length: 1) == "@" else { return false }
        guard start > 1 else { return true }
        let before = context.document.substring(utf16Offset: start - 2, length: 1)
        return before.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
    }
}
