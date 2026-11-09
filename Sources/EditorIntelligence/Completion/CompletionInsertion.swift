import Foundation

/// What accepting a completion item writes into the document, given the character that already
/// follows the replaced range. Pure, so the editor and the quality harness apply an item the same way.
public struct CompletionInsertion: Equatable, Sendable {
    public let text: String
    /// Caret offset (UTF-16) from the start of the replaced range, or `nil` for "after the text".
    public let caretOffset: Int?
    /// Whether `text` is still a snippet. An item reduced because of the following text is plain.
    public let isSnippet: Bool

    private static let typeKinds: Set<CompletionItemKind> = [.class, .interface, .enum, .type, .constructor, .annotation]

    /// Never writes what the developer has already typed after the caret:
    /// - `foo|(x)`: a method's trailing `()` is not written again and the caret steps into the pair.
    /// - `new Foo|<String>(x)`: only the type name is written (no `<>()`, no anonymous body).
    /// - `new Foo|(x) {`: the type name, plus the diamond when the item has one (`Foo<>` before `(`).
    /// - `(Foo|)`: a cast item's closing `) ` is not written when `)` follows.
    /// - `@A(value| = x)`: an annotation attribute's ` = ` is not written when `=` already follows.
    /// `following` is the text after the replaced range (a few characters are enough).
    public static func resolve(_ item: CompletionItem, nextCharacter: String?, following: String = "") -> CompletionInsertion {
        let original = item.insertText
        var text = original
        var caretOffset = item.caretOffset
        if typeKinds.contains(item.kind), let next = nextCharacter {
            let headEnd = text.firstIndex { "<( )".contains($0) } ?? text.endIndex
            let head = String(text[..<headEnd])
            let tail = text[headEnd...]
            if next == "<", tail.hasPrefix("<") || tail.hasPrefix("(") {
                text = head
                caretOffset = nil
            } else if next == "(", tail.hasPrefix("<>(") {
                text = head + "<>"
                caretOffset = (text as NSString).length + 1
            } else if next == "(", tail.hasPrefix("("), tail != "()" {
                // An anonymous-class body: keep the name, step into the parentheses already there.
                // (A plain `Foo()` is the method rule below: same text, same caret.)
                text = head
                caretOffset = (head as NSString).length + 1
            } else if next == ")", text.hasSuffix(") ") {
                text.removeLast(2)
                caretOffset = nil
            }
        }
        if text.hasSuffix(" = "), following.drop(while: { $0 == " " }).hasPrefix("=") {
            text.removeLast(3)
            caretOffset = nil
        }
        if text == original, text.hasSuffix("()"), nextCharacter == "(" {
            text.removeLast(2)
            caretOffset = (text as NSString).length + 1
        }
        return CompletionInsertion(text: text, caretOffset: caretOffset, isSnippet: item.isSnippet && text == original)
    }
}
