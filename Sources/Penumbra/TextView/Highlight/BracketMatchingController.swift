import Foundation

/// Finds and emphasizes matching bracket pairs at the caret.
final class BracketMatchingController {
    var stringView: StringView
    var characterPairs: [CharacterPair] = []
    var emphasisStyle: BracketPairEmphasis?
    weak var emphasisManager: EmphasisManager?

    private let searchLimit = 4096

    init(stringView: StringView) {
        self.stringView = stringView
    }

    func emphasizePairs(at location: Int) {
        guard let emphasisStyle, let emphasisManager else {
            return
        }
        emphasisManager.removeEmphases(for: EmphasisGroup.brackets)
        guard location > 0, location <= stringView.length else {
            return
        }
        guard let precedingCharacter = stringView.substring(in: NSRange(location: location - 1, length: 1)) else {
            return
        }
        for pair in characterPairs {
            if precedingCharacter == pair.leading {
                emphasizeForward(open: pair.leading, close: pair.trailing, caretLocation: location, style: emphasisStyle)
            } else if precedingCharacter == pair.trailing && location - 1 > 0 {
                emphasizeBackward(open: pair.leading, close: pair.trailing, caretLocation: location, style: emphasisStyle)
            }
        }
    }

    func clearEmphasis() {
        emphasisManager?.removeEmphases(for: EmphasisGroup.brackets)
    }
}

private extension BracketMatchingController {
    private func emphasizeForward(open: String, close: String, caretLocation: Int, style: BracketPairEmphasis) {
        let limit = min(caretLocation + searchLimit, stringView.length)
        guard let matchLocation = findClosingPair(close: close, open: open, from: caretLocation, limit: limit, reverse: false) else {
            return
        }
        var emphases: [Emphasis] = [emphasis(for: matchLocation, style: style, flashOppositeOnly: style == .flash)]
        if style.emphasizesSourceBracket {
            emphases.append(emphasis(for: caretLocation - 1, style: style, flashOppositeOnly: false))
        }
        emphasisManager?.addEmphases(emphases, for: EmphasisGroup.brackets, color: emphasisColor(for: style))
    }

    private func emphasizeBackward(open: String, close: String, caretLocation: Int, style: BracketPairEmphasis) {
        let limit = max(caretLocation - 1 - searchLimit, 0)
        guard let matchLocation = findClosingPair(close: close, open: open, from: caretLocation - 1, limit: limit, reverse: true) else {
            return
        }
        var emphases: [Emphasis] = [emphasis(for: matchLocation, style: style, flashOppositeOnly: style == .flash)]
        if style.emphasizesSourceBracket {
            emphases.append(emphasis(for: caretLocation - 1, style: style, flashOppositeOnly: false))
        }
        emphasisManager?.addEmphases(emphases, for: EmphasisGroup.brackets, color: emphasisColor(for: style))
    }

    private func emphasis(for location: Int, style: BracketPairEmphasis, flashOppositeOnly: Bool) -> Emphasis {
        let range = NSRange(location: location, length: 1)
        switch style {
        case .flash:
            return Emphasis(range: range, style: .standard, flash: flashOppositeOnly, inactive: false)
        case .bordered(let color):
            return Emphasis(range: range, style: .outline(color: color), flash: false, inactive: false)
        case .underline(let color):
            return Emphasis(range: range, style: .underline(color: color), flash: false, inactive: false)
        }
    }

    private func emphasisColor(for style: BracketPairEmphasis) -> UIColor {
        switch style {
        case .flash:
            return .systemYellow
        case .bordered(let color), .underline(let color):
            return color
        }
    }

    private func findClosingPair(close: String, open: String, from: Int, limit: Int, reverse: Bool) -> Int? {
        var options: NSString.EnumerationOptions = .byComposedCharacterSequences
        if reverse {
            options.insert(.reverse)
        }
        let searchRange = reverse
            ? NSRange(location: limit, length: from - limit + 1)
            : NSRange(location: from, length: limit - from)
        guard searchRange.length > 0 else {
            return nil
        }
        var closeCount = 0
        var matchLocation: Int?
        stringView.enumerateSubstrings(in: searchRange, options: options) { substring, range, _, stop in
            if substring == close {
                closeCount += 1
            } else if substring == open {
                closeCount -= 1
            }
            if closeCount < 0 {
                matchLocation = range.location
                stop.pointee = true
            }
        }
        return matchLocation
    }
}
