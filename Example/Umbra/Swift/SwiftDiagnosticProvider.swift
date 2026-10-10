import EditorIntelligence
import Foundation
import JavaIntelligence

/// Syntax problems from the tree. They are warnings. tree-sitter-swift 0.7.4, plus the local
/// patches in `grammar.js` and `scanner.c`, reads `nonisolated(unsafe)`, `#expect`, `#Preview`
/// with `@available` in front of it, `await` on a call or a property in `if` / `while` / `where`,
/// expression-valued `switch`/`if`, regex literals that include `\/` or start with an operator
/// character, multi-pattern `case … where`, a leading `^` or `*`, an empty tuple `()`, `didSet`
/// on an initialized property, a `///**` comment after an expression, `/*` and `*/` inside a line
/// string, a raw string nested in another raw string's interpolation, and `(T?, Array<U>).self`.
/// Syntax problems stay warnings: valid Swift outside this repository can still be rejected, and
/// calling that an error would mark it red. The compiler's own errors arrive from the build
/// (`SwiftBuildOutputParser`).
struct SwiftDiagnosticProvider: DiagnosticProvider {
    let name = SwiftAnalysis.providerName

    func diagnostics(for document: Document) async -> [Diagnostic] {
        guard document.languageIdentifier == SwiftAnalysis.languageIdentifier else { return [] }
        guard let parsed = SwiftAnalysis.parse(document: document) else { return [] }
        return parsed.model.errors.prefix(100).map { problem in
            var range = parsed.text.range(bytes: problem.bytes)
            if range.start.utf16Offset == range.end.utf16Offset {
                let end = min(range.end.utf16Offset + 1, parsed.text.utf16Length)
                if end > range.start.utf16Offset {
                    range = EditorIntelligence.TextRange(start: range.start, end: parsed.text.position(utf16: end))
                }
            }
            let message: String
            if problem.isMissing, let expected = problem.expected {
                message = "Expected '\(expected)'"
            } else {
                message = "Syntax error"
            }
            return Diagnostic(severity: .warning, message: message, range: range, source: name, code: "syntax")
        }
    }
}
