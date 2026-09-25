import CoreGraphics
import Foundation

final class PlainTextSyntaxHighlighter: LineSyntaxHighlighter {
    var theme: Theme = DefaultTheme.placeholder
    var kern: CGFloat = 0
    var canHighlight: Bool {
        false
    }
    var canEventuallyHighlight: Bool {
        false
    }

    func syntaxHighlight(_ input: LineSyntaxHighlighterInput) {}

    func syntaxHighlight(_ input: LineSyntaxHighlighterInput, completion: @escaping AsyncCallback) {
        completion(.success(()))
    }

    func cancel() {}
}
