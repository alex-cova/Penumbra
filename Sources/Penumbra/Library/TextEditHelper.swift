import Foundation

struct TextEditResult {
    let textChange: TextChange
    let lineChangeSet: LineChangeSet
    var didAddOrRemoveLines: Bool {
        let didAddLines = !lineChangeSet.insertedLines.isEmpty
        let didRemoveLines = !lineChangeSet.removedLines.isEmpty
        return didAddLines || didRemoveLines
    }
}

final class TextEditHelper {
    private let stringView: StringView
    private let lineManager: LineManager
    private let lineEndings: LineEnding

    init(stringView: StringView, lineManager: LineManager, lineEndings: LineEnding) {
        self.stringView = stringView
        self.lineManager = lineManager
        self.lineEndings = lineEndings
    }

    func replaceText(in range: NSRange, with newString: String) -> TextEditResult {
        let documentLength = stringView.length
        let location = min(max(range.location, 0), documentLength)
        let clampedLength = min(max(range.length, 0), documentLength - location)
        let range = NSRange(location: location, length: clampedLength)
        let nsNewString = newString as NSString
        let byteRange = ByteRange(utf16Range: range)
        let oldEndLinePosition = lineManager.linePosition(at: range.location + range.length)
            ?? lineManager.linePosition(at: documentLength)
            ?? LinePosition(row: 0, column: 0)
        stringView.replaceText(in: range, with: newString)
        let lineChangeSet = LineChangeSet()
        let lineChangeSetFromRemovingCharacters = lineManager.removeCharacters(in: range)
        lineChangeSet.union(with: lineChangeSetFromRemovingCharacters)
        let lineChangeSetFromInsertingCharacters = lineManager.insert(nsNewString, at: range.location)
        lineChangeSet.union(with: lineChangeSetFromInsertingCharacters)
        let startLinePosition = lineManager.linePosition(at: range.location)
            ?? LinePosition(row: 0, column: 0)
        let newEndLinePosition = lineManager.linePosition(at: range.location + nsNewString.length)
            ?? startLinePosition
        let textChange = TextChange(byteRange: byteRange,
                                    bytesAdded: newString.byteCount,
                                    oldEndLinePosition: oldEndLinePosition,
                                    startLinePosition: startLinePosition,
                                    newEndLinePosition: newEndLinePosition)
        return TextEditResult(textChange: textChange, lineChangeSet: lineChangeSet)
    }

    func string(byApplying batchReplaceSet: BatchReplaceSet) -> NSString {
        _ = apply(batchReplaceSet)
        return (stringView.substring(in: NSRange(location: 0, length: stringView.length)) ?? "") as NSString
    }

    /// Result of applying a batch replacement, including its inverse — replacing
    /// `inverseReplacements` in the resulting document restores the original.
    /// `inverseReplacements` is sized to the edited ranges (like a normal single-edit undo
    /// delta), not to the whole document, so it can back an undo registration without cloning
    /// the full string. See PERFORMANCE_AUDIT.md Phase 2 #7.
    struct BatchApplication {
        let inverseReplacements: [BatchReplaceSet.Replacement]
    }

    func apply(_ batchReplaceSet: BatchReplaceSet) -> BatchApplication {
        let sortedReplacements = batchReplaceSet.replacements.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var totalChangeInLength = 0
        var replacedRanges: [NSRange] = []
        var inverseReplacements: [BatchReplaceSet.Replacement] = []
        for replacement in sortedReplacements where !replacedRanges.contains(where: { $0.overlaps(replacement.range) }) {
            let range = replacement.range
            let adjustedRange = NSRange(location: range.location + totalChangeInLength, length: range.length)
            let oldText = stringView.substring(in: adjustedRange) ?? ""
            _ = replaceText(in: adjustedRange, with: replacement.text)
            replacedRanges.append(replacement.range)
            totalChangeInLength += replacement.text.utf16.count - adjustedRange.length
            let newRange = NSRange(location: adjustedRange.location, length: (replacement.text as NSString).length)
            inverseReplacements.append(BatchReplaceSet.Replacement(range: newRange, text: oldText))
        }
        return BatchApplication(inverseReplacements: inverseReplacements)
    }
}
