import Foundation

/// What a ``BasicCharacterPair`` surrounds, which decides where typing its leading component
/// also inserts the trailing one.
public enum CharacterPairKind: Equatable, Sendable {
    /// `()`, `[]`, `{}`: paired when the caret is not directly in front of an identifier.
    case bracket
    /// `"`, `'`, `` ` ``: like ``bracket``, and not after an identifier character (`don't`).
    case quote
    /// `<>` around generic arguments: paired only right after a type name (`List<`), so `a < b`
    /// is typed as written.
    case genericAngle
}

/// A character pair that is only completed where it makes sense for its ``kind``.
///
/// With a selection the pair always wraps it; the context rules apply to a plain caret.
public struct BasicCharacterPair: CharacterPair, Equatable, Sendable {
    public let leading: String
    public let trailing: String
    public let kind: CharacterPairKind

    public init(leading: String, trailing: String, kind: CharacterPairKind) {
        self.leading = leading
        self.trailing = trailing
        self.kind = kind
    }
}

/// The context test behind ``BasicCharacterPair``. Pure, so it is tested without a text view.
enum CharacterPairContext {
    /// How much text before the caret ``shouldAutoInsert(kind:textBefore:textAfter:)`` needs.
    static let lookBehindLength = 64
    /// How much text after the caret it needs.
    static let lookAheadLength = 4

    private static let closers: Set<Character> = [")", "]", "}", ">", ";", ",", ".", ":"]

    /// - Parameters:
    ///   - textBefore: Up to ``lookBehindLength`` UTF-16 units in front of the caret.
    ///   - textAfter: Up to ``lookAheadLength`` UTF-16 units after the caret.
    static func shouldAutoInsert(kind: CharacterPairKind, textBefore: String, textAfter: String) -> Bool {
        guard nextAllowsPair(textAfter.first) else {
            return false
        }
        switch kind {
        case .bracket:
            return true
        case .quote:
            guard let previous = textBefore.last else {
                return true
            }
            return !(isIdentifierCharacter(previous) || previous == "\\" || previous == "\"" || previous == "'" || previous == "`")
        case .genericAngle:
            let name = textBefore.reversed().prefix(while: isIdentifierCharacter)
            // `name` is reversed: its last element is the identifier's first character.
            guard let first = name.last else {
                return false
            }
            return first.isUppercase
        }
    }

    private static func nextAllowsPair(_ next: Character?) -> Bool {
        guard let next else {
            return true
        }
        return next.isWhitespace || closers.contains(next)
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "$"
    }
}
