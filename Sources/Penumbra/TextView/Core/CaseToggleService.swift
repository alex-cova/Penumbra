import Foundation

/// Pure case cycling for ``TextView/toggleCase()`` (⌘⇧U): lower → UPPER → Title → lower,
/// matching IntelliJ's Toggle Case.
enum CaseToggleService {
    enum CaseForm {
        case lower
        case upper
        case title
    }

    static func detectedForm(of text: String) -> CaseForm {
        guard text.contains(where: \.isLetter) else { return .lower }
        if text == text.uppercased() { return .upper }
        if text == text.lowercased() { return .lower }
        if isTitleCase(text) { return .title }
        return .lower
    }

    static func nextForm(after form: CaseForm) -> CaseForm {
        switch form {
        case .lower: .upper
        case .upper: .title
        case .title: .lower
        }
    }

    static func transform(_ text: String, to form: CaseForm) -> String {
        switch form {
        case .lower: text.lowercased()
        case .upper: text.uppercased()
        case .title: toTitleCase(text)
        }
    }

    static func toggled(_ text: String) -> String {
        transform(text, to: nextForm(after: detectedForm(of: text)))
    }

    private static func isTitleCase(_ text: String) -> Bool {
        var index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex, !text[index].isLetter {
                index = text.index(after: index)
            }
            guard index < text.endIndex else { break }
            if !text[index].isUppercase { return false }
            index = text.index(after: index)
            while index < text.endIndex, text[index].isLetter {
                if text[index].isUppercase { return false }
                index = text.index(after: index)
            }
        }
        return true
    }

    private static func toTitleCase(_ text: String) -> String {
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isLetter {
                let wordStart = index
                while index < text.endIndex, text[index].isLetter {
                    index = text.index(after: index)
                }
                let word = String(text[wordStart..<index])
                result += word.prefix(1).uppercased() + word.dropFirst().lowercased()
            } else {
                result.append(text[index])
                index = text.index(after: index)
            }
        }
        return result
    }
}
