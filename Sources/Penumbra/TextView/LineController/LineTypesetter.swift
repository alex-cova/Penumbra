import CoreGraphics
import CoreText
import Foundation

private final class TypesetResult {
    let lineFragments: [LineFragment]
    let lineFragmentsMap: [LineFragmentID: Int]
    let maximumLineWidth: CGFloat

    init(lineFragments: [LineFragment], lineFragmentsMap: [LineFragmentID: Int], maximumLineWidth: CGFloat) {
        self.lineFragments = lineFragments
        self.lineFragmentsMap = lineFragmentsMap
        self.maximumLineWidth = maximumLineWidth
    }
}

final class LineTypesetter {
    private enum TypesetEndCondition {
        case yPosition(_ targetYPosition: CGFloat)
        case characterIndex(_ targetCharacterIndex: Int)

        func shouldKeepTypesetting(currentYPosition: CGFloat, currentCharacterIndex: Int) -> Bool {
            switch self {
            case .yPosition(let targetYPosition):
                return currentYPosition < targetYPosition
            case .characterIndex(let targetCharacterIndex):
                return currentCharacterIndex < targetCharacterIndex
            }
        }
    }

    var lineBreakMode: LineBreakMode = .byWordWrapping
    var constrainingWidth: CGFloat = 0
    var lineFragmentHeightMultiplier: CGFloat = 1
    /// Room above the first fragment (a code vision lens). Applied by ``reset()``.
    var topInset: CGFloat = 0
    private(set) var lineFragments: [LineFragment] = []
    private(set) var maximumLineWidth: CGFloat = 0
    /// `CTTypesetterCreateLine` calls made by this typesetter; tests and benchmarks compare it with
    /// the number of fragments to see how many lines were built and thrown away.
    private(set) var createdLineCount = 0
    var bestGuessNumberOfLineFragments: Int {
        if startOffset >= stringLength {
            return lineFragments.count
        } else {
            let charactersPerLineFragment = Double(startOffset) / Double(lineFragments.count)
            let charactersRemaining = stringLength - startOffset
            let remainingNumberOfLineFragments = Int(ceil(Double(charactersRemaining) / charactersPerLineFragment))
            return lineFragments.count + remainingNumberOfLineFragments
        }
    }
    var isFinishedTypesetting: Bool {
        startOffset >= stringLength
    }
    var typesetLength: Int {
        startOffset
    }

    private let lineID: String
    private var stringLength = 0
    private var attributedString: NSAttributedString?
    private var typesetter: CTTypesetter?
    private var lineFragmentsMap: [LineFragmentID: Int] = [:]
    private var startOffset = 0
    private var nextYPosition: CGFloat = 0
    private var lineFragmentIndex = 0

    init(lineID: String) {
        self.lineID = lineID
    }

    func reset() {
        lineFragments = []
        maximumLineWidth = 0
        stringLength = 0
        attributedString = nil
        typesetter = nil
        lineFragmentsMap = [:]
        startOffset = 0
        nextYPosition = topInset
        lineFragmentIndex = 0
    }

    func prepareToTypeset(_ attributedString: NSAttributedString) {
        self.attributedString = attributedString
        stringLength = CFAttributedStringGetLength(attributedString)
        typesetter = CTTypesetterCreateWithAttributedString(attributedString)
    }

    @discardableResult
    func typesetLineFragments(in rect: CGRect) -> [LineFragment] {
        let lineFragments = typesetLineFragments(until: .yPosition(rect.maxY))
        if isFinishedTypesetting {
            attributedString = nil
            typesetter = nil
        }
        return lineFragments
    }

    @discardableResult
    func typesetLineFragments(toLocation location: Int, additionalLineFragmentCount: Int = 0) -> [LineFragment] {
        let lineFragments = typesetLineFragments(until: .characterIndex(location), additionalLineFragmentCount: additionalLineFragmentCount)
        if isFinishedTypesetting {
            attributedString = nil
            typesetter = nil
        }
        return lineFragments
    }

    func lineFragment(withID lineFragmentID: LineFragmentID) -> LineFragment? {
        if let index = lineFragmentsMap[lineFragmentID] {
            return lineFragments[index]
        } else {
            return nil
        }
    }
}

private extension LineTypesetter {
    private func updateState(from typesetResult: TypesetResult) {
        lineFragments.append(contentsOf: typesetResult.lineFragments)
        for (id, index) in typesetResult.lineFragmentsMap {
            lineFragmentsMap[id] = index
        }
        maximumLineWidth = max(maximumLineWidth, typesetResult.maximumLineWidth)
    }

    private func typesetLineFragments(until condition: TypesetEndCondition, additionalLineFragmentCount: Int = 0) -> [LineFragment] {
        guard let typesetter = typesetter else {
            return []
        }
        let typesetResult = typesetLineFragments(
            until: condition,
            additionalLineFragmentCount: additionalLineFragmentCount,
            using: typesetter,
            stringLength: stringLength
        )
        updateState(from: typesetResult)
        return typesetResult.lineFragments
    }

    private func typesetLineFragments(
        until condition: TypesetEndCondition,
        additionalLineFragmentCount: Int = 0,
        using typesetter: CTTypesetter,
        stringLength: Int
    ) -> TypesetResult {
        guard constrainingWidth > 0 else {
            return TypesetResult(lineFragments: [], lineFragmentsMap: [:], maximumLineWidth: 0)
        }
        var maximumLineWidth: CGFloat = 0
        var lineFragments: [LineFragment] = []
        var lineFragmentsMap: [LineFragmentID: Int] = [:]
        var remainingAdditionalLineFragmentCount = additionalLineFragmentCount
        let conditionAllowsKeepTypesetting = condition.shouldKeepTypesetting(currentYPosition: nextYPosition, currentCharacterIndex: startOffset)
        var shouldKeepTypesetting = conditionAllowsKeepTypesetting || remainingAdditionalLineFragmentCount > 0
        while startOffset < stringLength && shouldKeepTypesetting, let lineFragment = makeNextLineFragment(using: typesetter) {
            lineFragments.append(lineFragment)
            nextYPosition += lineFragment.scaledSize.height
            startOffset += lineFragment.range.length
            if lineFragment.scaledSize.width > maximumLineWidth {
                maximumLineWidth = lineFragment.scaledSize.width
            }
            lineFragmentsMap[lineFragment.id] = lineFragmentIndex
            lineFragmentIndex += 1
            if condition.shouldKeepTypesetting(currentYPosition: nextYPosition, currentCharacterIndex: startOffset) {
                shouldKeepTypesetting = true
            } else if remainingAdditionalLineFragmentCount > 0 {
                shouldKeepTypesetting = true
                remainingAdditionalLineFragmentCount -= 1
            } else {
                shouldKeepTypesetting = false
            }
        }
        return TypesetResult(lineFragments: lineFragments, lineFragmentsMap: lineFragmentsMap, maximumLineWidth: maximumLineWidth)
    }

    private func makeNextLineFragment(using typesetter: CTTypesetter) -> LineFragment? {
        // suggestNextLineBreak(using:) uses CTTypesetterSuggestLineBreak but it may return lines that are longer than our constraining width
        // (it lets trailing whitespace hang past the edge). In that case we take the longest prefix that fits.
        let suggestedLength = suggestNextLineBreak(using: typesetter)
        guard suggestedLength > 0, let (lineFragment, length) = longestFittingLineFragment(upTo: suggestedLength, using: typesetter) else {
            return nil
        }
        // `lengthOfWhitespace(after:)` takes the index of the fragment's last character.
        let whitespaceLength = lengthOfWhitespace(after: startOffset + length - 1)
        guard whitespaceLength > 0 else {
            return lineFragment
        }
        return lineFragment.withHiddenLength(whitespaceLength)
    }

    /// The fragment for the longest prefix of at most `maximumLength` characters that is no wider
    /// than the constraining width, or the one-character fragment when not even that fits.
    ///
    /// The prefix is usually the whole suggestion: one `CTLine`. When it overhangs (a long run of
    /// spaces after the break, say) the old search dropped one character at a time and rebuilt the
    /// line each time, 1,900 lines for a 2,000-space run. `CTTypesetterSuggestClusterBreak` says
    /// how many characters fit, so the search starts there, checks its neighbours, and falls back to
    /// bisection when the guess is off, which bounds it at log2(length) lines either way.
    private func longestFittingLineFragment(
        upTo maximumLength: Int,
        using typesetter: CTTypesetter
    ) -> (LineFragment, Int)? {
        func fragment(_ length: Int) -> LineFragment {
            makeLineFragment(
                for: CFRangeMake(startOffset, length),
                in: typesetter,
                lineFragmentIndex: lineFragmentIndex,
                yPosition: nextYPosition
            )
        }
        let whole = fragment(maximumLength)
        if whole.scaledSize.width <= constrainingWidth || maximumLength == 1 {
            return (whole, maximumLength)
        }
        var best: (LineFragment, Int)?
        var low = 1
        var high = maximumLength - 1
        let guess = CTTypesetterSuggestClusterBreak(typesetter, startOffset, Double(constrainingWidth))
        var probe = min(max(guess, low), high)
        var probesNearGuess = 2
        while low <= high {
            let candidate = fragment(probe)
            if candidate.scaledSize.width <= constrainingWidth {
                best = (candidate, probe)
                low = probe + 1
            } else {
                high = probe - 1
            }
            if probesNearGuess > 0 {
                // First the guess, then the neighbour on the side the guess says the answer is on.
                probesNearGuess -= 1
                probe = best?.1 == probe ? probe + 1 : probe - 1
                if probe < low || probe > high {
                    probesNearGuess = 0
                    probe = (low + high) / 2
                }
            } else {
                probe = (low + high) / 2
            }
        }
        if let best {
            return best
        }
        return (fragment(1), 1)
    }

    private func suggestNextLineBreak(using typesetter: CTTypesetter) -> Int {
        guard let attributedString else {
            return stringLength
        }
        let lineBreakSuggester = LineBreakSuggester(
            lineBreakMode: lineBreakMode,
            typesetter: typesetter,
            attributedString: attributedString,
            constrainingWidth: constrainingWidth
        )
        return lineBreakSuggester.suggestLineBreak(startingAt: startOffset)
    }

    private func lengthOfWhitespace(after location: Int) -> Int {
        guard let attributedString, location < attributedString.length - 1 else {
            return 0
        }
        var nextCharacter = location + 1
        var length = 0
        while attributedString.isWhitespaceCharacter(at: nextCharacter) {
            nextCharacter += 1
            length += 1
        }
        return length
    }

    private func makeLineFragment(
        for visibleRange: CFRange,
        in typesetter: CTTypesetter,
        lineFragmentIndex: Int,
        yPosition: CGFloat
    ) -> LineFragment {
        createdLineCount += 1
        let line = CTTypesetterCreateLine(typesetter, visibleRange)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let height = ascent + descent + leading
        let baseSize = CGSize(width: width, height: height)
        let scaledSize = CGSize(width: width, height: height * lineFragmentHeightMultiplier)
        let id = LineFragmentID(lineId: lineID, lineFragmentIndex: lineFragmentIndex)
        let visibleRange = NSRange(location: visibleRange.location, length: visibleRange.length)
        return LineFragment(
            id: id,
            index: lineFragmentIndex,
            visibleRange: visibleRange,
            line: line,
            descent: descent,
            baseSize: baseSize,
            scaledSize: scaledSize,
            yPosition: yPosition
        )
    }
}
