import CoreFoundation
import Foundation

extension NSAttributedString {
    func isWhitespaceCharacter(at location: Int) -> Bool {
        guard let scalar = scalar(atUTF16: location) else {
            return false
        }
        return CharacterSet.whitespaces.contains(scalar)
    }

    /// Whether a line may break after the character at `location`: a space, tab or other
    /// whitespace, or punctuation. A lone surrogate half is neither.
    func prefersLineBreak(after location: Int) -> Bool {
        guard let scalar = scalar(atUTF16: location) else {
            return false
        }
        return CharacterSet.whitespaces.contains(scalar) || CharacterSet.punctuationCharacters.contains(scalar)
    }

    /// The scalar of the one UTF-16 unit at `location`, read from the backing `CFString` without
    /// building a substring (an attributed substring, a `String` and a `CharacterSet` per
    /// character made the word-wrap lookback and the hidden-whitespace count the cost of a long
    /// token). Nil outside the string and for a surrogate half.
    private func scalar(atUTF16 location: Int) -> Unicode.Scalar? {
        guard location >= 0, location < length else {
            return nil
        }
        let backing = CFAttributedStringGetString(self as CFAttributedString)
        return Unicode.Scalar(UInt32(CFStringGetCharacterAtIndex(backing, location)))
    }
}
