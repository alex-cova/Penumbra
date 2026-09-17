import Foundation
@preconcurrency import AppKit

final class TextInputStringTokenizer: UITextInputStringTokenizer {
    var lineManager: LineManager
    var stringView: StringView
    weak var foldingController: FoldingController?
    // Used to ensure we can workaround bug where multi-stage input, like when entering Korean text
    // does not work properly. If we do not treat navigation between word boundies as a special case then
    // navigating with Shift + Option + Arrow Keys followed by Shift + Arrow Keys will not work correctly.
    var didCallPositionFromPositionToWordBoundary = false

    private let lineControllerStorage: LineControllerStorage

    init(textInput: UIResponder & UITextInput, stringView: StringView, lineManager: LineManager, lineControllerStorage: LineControllerStorage) {
        self.lineManager = lineManager
        self.stringView = stringView
        self.lineControllerStorage = lineControllerStorage
        super.init(textInput: textInput)
    }

    override func isPosition(_ position: UITextPosition, atBoundary granularity: UITextGranularity, inDirection direction: UITextDirection) -> Bool {
        if granularity == .line {
            return isPosition(position, atLineBoundaryInDirection: direction)
        } else if granularity == .paragraph {
            return isPosition(position, atParagraphBoundaryInDirection: direction)
        } else if granularity == .word {
            return isPosition(position, atWordBoundaryInDirection: direction)
        } else {
            return super.isPosition(position, atBoundary: granularity, inDirection: direction)
        }
    }

    override func position(from position: UITextPosition,
                           toBoundary granularity: UITextGranularity,
                           inDirection direction: UITextDirection) -> UITextPosition? {
        if granularity == .line {
            return self.position(from: position, toLineBoundaryInDirection: direction)
        } else if granularity == .paragraph {
            return self.position(from: position, toParagraphBoundaryInDirection: direction)
        } else if granularity == .word {
            return self.position(from: position, toWordBoundaryInDirection: direction)
        } else {
            return super.position(from: position, toBoundary: granularity, inDirection: direction)
        }
    }
}

// MARK: - Lines
private extension TextInputStringTokenizer {
    private func isPosition(_ position: UITextPosition, atLineBoundaryInDirection direction: UITextDirection) -> Bool {
        guard let indexedPosition = position as? IndexedPosition else {
            return false
        }
        let location = adjustedLocation(forNavigation: indexedPosition.index, direction: direction)
        guard let line = visibleLine(containingCharacterAt: location) else {
            return false
        }
        let lineLocation = line.location
        let lineLocalLocation = location - lineLocation
        let lineController = lineControllerStorage.getOrCreateLineController(for: line)
        guard lineLocalLocation >= 0 && lineLocalLocation <= line.data.totalLength else {
            return false
        }
        guard let lineFragmentNode = lineController.lineFragmentNode(containingCharacterAt: lineLocalLocation) else {
            return false
        }
        if direction.isForward {
            let isLastLineFragment = lineFragmentNode.index == lineController.numberOfLineFragments - 1
            if isLastLineFragment {
                return location == lineLocation + lineFragmentNode.location + lineFragmentNode.value - line.data.delimiterLength
            } else {
                return location == lineLocation + lineFragmentNode.location + lineFragmentNode.value
            }
        } else {
            return location == lineLocation + lineFragmentNode.location
        }
    }

    private func position(from position: UITextPosition, toLineBoundaryInDirection direction: UITextDirection) -> UITextPosition? {
        guard let indexedPosition = position as? IndexedPosition else {
            return nil
        }
        let location = adjustedLocation(forNavigation: indexedPosition.index, direction: direction)
        guard let line = visibleLine(containingCharacterAt: location) else {
            return nil
        }
        let lineController = lineControllerStorage.getOrCreateLineController(for: line)
        let lineLocation = line.location
        let lineLocalLocation = location - lineLocation
        guard let lineFragmentNode = lineController.lineFragmentNode(containingCharacterAt: lineLocalLocation) else {
            return nil
        }
        if direction.isForward {
            if location == stringView.length {
                return position
            } else {
                let lineFragmentRangeUpperBound = lineFragmentNode.location + lineFragmentNode.value
                let preferredLocation = lineLocation + lineFragmentRangeUpperBound
                let lineEndLocation = lineLocation + line.data.totalLength
                if preferredLocation == lineEndLocation {
                    // Navigate to end of line but before the delimiter (\n etc.)
                    return IndexedPosition(index: preferredLocation - line.data.delimiterLength)
                } else {
                    // Navigate to the end of the line but before the last character. This is a hack that avoids an issue where the caret is placed on the next line. The approach seems to be similar to what Textastic is doing.
                    let lastCharacterRange = stringView.rangeOfComposedCharacterSequence(at: lineFragmentRangeUpperBound)
                    return IndexedPosition(index: lineLocation + lineFragmentRangeUpperBound - lastCharacterRange.length)
                }
            }
        } else if location == 0 {
            return position
        } else {
            return IndexedPosition(index: lineLocation + lineFragmentNode.location)
        }
    }
}

// MARK: - Paragraphs
private extension TextInputStringTokenizer {
    private func isPosition(_ position: UITextPosition, atParagraphBoundaryInDirection direction: UITextDirection) -> Bool {
        // I can't seem to make Ctrl+A, Ctrl+E, Cmd+Left, and Cmd+Right work properly if this function returns anything but false.
        // I've tried various ways of determining the paragraph boundary but UIKit doesn't seem to be happy with anything I come up with ultimately leading to incorrect keyboard navigation. I haven't yet found any drawbacks to returning false in all cases.
        false
    }

    private func position(from position: UITextPosition, toParagraphBoundaryInDirection direction: UITextDirection) -> UITextPosition? {
        guard let indexedPosition = position as? IndexedPosition else {
            return nil
        }
        let location = indexedPosition.index
        if direction.isForward {
            if location == stringView.length {
                return position
            }
            let searchFrom = adjustedLocation(forNavigation: location, direction: direction)
            if let newline = stringView.rangeOfNextNewLine(startingAt: searchFrom) {
                return IndexedPosition(index: newline.location)
            }
            return IndexedPosition(index: stringView.length)
        }
        if location == 0 {
            return position
        }
        let searchFrom = adjustedLocation(forNavigation: location, direction: direction)
        return IndexedPosition(index: stringView.paragraphStart(before: searchFrom))
    }
}

// MARK: - Words
private extension TextInputStringTokenizer {
    private func isPosition(_ position: UITextPosition, atWordBoundaryInDirection direction: UITextDirection) -> Bool {
        guard let indexedPosition = position as? IndexedPosition else {
            return false
        }
        let location = indexedPosition.index
        let alphanumerics = CharacterSet.alphanumerics
        if direction.isForward {
            if location == 0 {
                return false
            } else if let previousCharacter = stringView.character(at: location - 1) {
                if location == stringView.length {
                    return alphanumerics.contains(previousCharacter)
                } else if let character = stringView.character(at: location) {
                    return alphanumerics.contains(previousCharacter) && !alphanumerics.contains(character)
                } else {
                    return false
                }
            } else {
                return false
            }
        } else {
            if location == stringView.length {
                return false
            } else if let character = stringView.character(at: location) {
                if location == 0 {
                    return alphanumerics.contains(character)
                } else if let previousCharacter = stringView.character(at: location - 1) {
                    return alphanumerics.contains(character) && !alphanumerics.contains(previousCharacter)
                } else {
                    return false
                }
            } else {
                return false
            }
        }
    }

    private func position(from position: UITextPosition, toWordBoundaryInDirection direction: UITextDirection) -> UITextPosition? {
        guard let indexedPosition = position as? IndexedPosition else {
            return nil
        }
        didCallPositionFromPositionToWordBoundary = true
        let location = indexedPosition.index
        let alphanumerics = CharacterSet.alphanumerics
        if direction.isForward {
            if location == stringView.length {
                return position
            }
            guard let referenceCharacter = stringView.character(at: location) else {
                return nil
            }
            let searchSet: CharacterSet = alphanumerics.contains(referenceCharacter)
                ? alphanumerics.inverted
                : alphanumerics
            let start = location + 1
            let length = stringView.length - start
            guard length > 0 else {
                return IndexedPosition(index: stringView.length)
            }
            let found = stringView.rangeOfCharacter(
                from: searchSet,
                options: [],
                range: NSRange(location: start, length: length)
            )
            if found.location == NSNotFound {
                return IndexedPosition(index: stringView.length)
            }
            return IndexedPosition(index: found.location)
        }
        if location == 0 {
            return position
        }
        guard let referenceCharacter = stringView.character(at: location - 1) else {
            return nil
        }
        let searchSet: CharacterSet = alphanumerics.contains(referenceCharacter)
            ? alphanumerics.inverted
            : alphanumerics
        let searchLength = location - 1
        guard searchLength > 0 else {
            return IndexedPosition(index: 0)
        }
        let found = stringView.rangeOfCharacter(
            from: searchSet,
            options: .backwards,
            range: NSRange(location: 0, length: searchLength)
        )
        if found.location == NSNotFound {
            return IndexedPosition(index: 0)
        }
        return IndexedPosition(index: found.location + found.length)
    }
}

private extension TextInputStringTokenizer {
    private func adjustedLocation(forNavigation location: Int, direction: UITextDirection) -> Int {
        guard let foldingController else {
            return location
        }
        if direction.isForward {
            return foldingController.visibleLocationForForwardNavigation(from: location)
        } else {
            return foldingController.visibleLocationForBackwardNavigation(from: location)
        }
    }

    private func visibleLine(containingCharacterAt location: Int) -> DocumentLineNode? {
        guard location >= 0 else {
            return nil
        }
        let safeLocation = min(location, max(stringView.length - 1, 0))
        guard stringView.length > 0 else {
            return nil
        }
        guard let line = lineManager.line(containingCharacterAt: safeLocation) else {
            return nil
        }
        if let foldingController, foldingController.isLineHidden(line.id) {
            return foldingController.lastVisibleLine(atOrBeforeRow: line.index)
                ?? foldingController.firstVisibleLine(atOrAfterRow: line.index)
        }
        return line
    }
}

private extension UITextDirection {
    var isForward: Bool {
        if self == .backward {
            return false
        }
        if self == .forward {
            return true
        }
        return rawValue == UITextLayoutDirection.right.rawValue
            || rawValue == UITextLayoutDirection.down.rawValue
    }
}

private extension CharacterSet {
    func contains(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(contains(_:))
    }
}
