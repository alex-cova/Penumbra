import Foundation
@preconcurrency import AppKit

final class LineMovementController {
    var lineManager: LineManager
    var stringView: StringView
    let lineControllerStorage: LineControllerStorage
    weak var foldingController: FoldingController?

    init(lineManager: LineManager, stringView: StringView, lineControllerStorage: LineControllerStorage) {
        self.lineManager = lineManager
        self.stringView = stringView
        self.lineControllerStorage = lineControllerStorage
    }

    func location(from location: Int, in direction: UITextLayoutDirection, offset: Int) -> Int? {
        let newLocation: Int?
        switch direction {
        case .left:
            newLocation = locationForMoving(fromLocation: location, by: offset * -1)
        case .right:
            newLocation = locationForMoving(fromLocation: location, by: offset)
        case .up:
            newLocation = locationForMoving(lineOffset: offset * -1, fromLineContainingCharacterAt: location)
        case .down:
            newLocation = locationForMoving(lineOffset: offset, fromLineContainingCharacterAt: location)
        @unknown default:
            newLocation = nil
        }
        if let newLocation = newLocation, newLocation >= 0 && newLocation <= stringView.length {
            return newLocation
        } else {
            return nil
        }
    }
}

private extension LineMovementController {
    private func locationForMoving(fromLocation location: Int, by offset: Int) -> Int {
        let naiveNewLocation = location + offset
        guard naiveNewLocation >= 0 && naiveNewLocation <= stringView.length else {
            return location
        }
        // Skip over an entire folded (hidden) region in one step, the same way real editors treat
        // a collapsed fold as a single atomic unit for arrow-key movement, rather than letting the
        // caret tunnel through its individually-hidden characters one grapheme at a time.
        if let foldingController,
           let hiddenLine = lineManager.line(containingCharacterAt: naiveNewLocation),
           foldingController.isLineHidden(hiddenLine.id),
           let fold = foldingController.collapsedFold(hidingLineID: hiddenLine.id) {
            if offset < 0 {
                let headerLine = lineManager.line(atRow: fold.lineRange.lowerBound)
                return headerLine.location + headerLine.data.length
            } else {
                let afterRow = fold.lineRange.upperBound + 1
                if afterRow < lineManager.lineCount {
                    return lineManager.line(atRow: afterRow).location
                } else {
                    return stringView.length
                }
            }
        }
        guard naiveNewLocation > 0 && naiveNewLocation < stringView.length else {
            return naiveNewLocation
        }
        let range = stringView.rangeOfComposedCharacterSequence(at: naiveNewLocation)
        guard naiveNewLocation > range.location && naiveNewLocation < range.location + range.length else {
            return naiveNewLocation
        }
        if offset < 0 {
            return location - range.length
        } else {
            return location + range.length
        }
    }

    private func locationForMoving(lineOffset: Int, fromLineContainingCharacterAt location: Int) -> Int {
        guard let line = lineManager.line(containingCharacterAt: location) else {
            return location
        }
        guard let lineController = lineControllerStorage[line.id] else {
            return location
        }
        let lineLocalLocation = max(min(location - line.location, line.data.totalLength), 0)
        guard let lineFragmentNode = lineController.lineFragmentNode(containingCharacterAt: lineLocalLocation) else {
            return location
        }
        let lineFragmentLocalLocation = lineLocalLocation - lineFragmentNode.location
        return locationForMoving(lineOffset: lineOffset, fromLocation: lineFragmentLocalLocation, inLineFragmentAt: lineFragmentNode.index, of: line)
    }

    private func locationForMoving(lineOffset: Int,
                                   fromLocation location: Int,
                                   inLineFragmentAt lineFragmentIndex: Int,
                                   of line: DocumentLineNode) -> Int {
        if lineOffset < 0 {
            return locationForMovingUpwards(lineOffset: abs(lineOffset), fromLocation: location, inLineFragmentAt: lineFragmentIndex, of: line)
        } else if lineOffset > 0 {
            return locationForMovingDownwards(lineOffset: lineOffset, fromLocation: location, inLineFragmentAt: lineFragmentIndex, of: line)
        } else {
            // lineOffset is 0 so we shouldn't change the line
            let lineController = lineControllerStorage.getOrCreateLineController(for: line)
            let destinationLineFragmentNode = lineController.lineFragmentNode(atIndex: lineFragmentIndex)
            let lineLocation = line.location
            let preferredLocation = lineLocation + destinationLineFragmentNode.location + location
            let lineFragmentMaximumLocation = lineLocation + destinationLineFragmentNode.location + destinationLineFragmentNode.value
            let lineMaximumLocation = lineLocation + line.data.length
            let maximumLocation = min(lineFragmentMaximumLocation, lineMaximumLocation)
            return min(preferredLocation, maximumLocation)
        }
    }

    private func locationForMovingUpwards(lineOffset: Int,
                                          fromLocation location: Int,
                                          inLineFragmentAt lineFragmentIndex: Int,
                                          of line: DocumentLineNode) -> Int {
        let takeLineCount = min(lineFragmentIndex, lineOffset)
        let remainingLineOffset = lineOffset - takeLineCount
        guard remainingLineOffset > 0 else {
            return locationForMoving(lineOffset: 0, fromLocation: location, inLineFragmentAt: lineFragmentIndex - takeLineCount, of: line)
        }
        let lineIndex = line.index
        guard lineIndex > 0 else {
            // We've reached the beginning of the document so we move to the first character.
            return 0
        }
        var previousLine = lineManager.line(atRow: lineIndex - 1)
        while let foldingController, foldingController.isLineHidden(previousLine.id), previousLine.index > 0 {
            previousLine = lineManager.line(atRow: previousLine.index - 1)
        }
        let numberOfLineFragments = numberOfLineFragments(in: previousLine)
        let newLineFragmentIndex = numberOfLineFragments - 1
        return locationForMovingUpwards(lineOffset: remainingLineOffset - 1,
                                        fromLocation: location,
                                        inLineFragmentAt: newLineFragmentIndex,
                                        of: previousLine)
    }

    private func locationForMovingDownwards(lineOffset: Int,
                                            fromLocation location: Int,
                                            inLineFragmentAt lineFragmentIndex: Int,
                                            of line: DocumentLineNode) -> Int {
        let numberOfLineFragments = numberOfLineFragments(in: line)
        let takeLineCount = min(numberOfLineFragments - lineFragmentIndex - 1, lineOffset)
        let remainingLineOffset = lineOffset - takeLineCount
        guard remainingLineOffset > 0 else {
            return locationForMoving(lineOffset: 0, fromLocation: location, inLineFragmentAt: lineFragmentIndex + takeLineCount, of: line)
        }
        let lineIndex = line.index
        guard lineIndex < lineManager.lineCount - 1 else {
            // We've reached the end of the document so we move to the last character.
            return line.location + line.data.totalLength
        }
        var nextLine = lineManager.line(atRow: lineIndex + 1)
        while let foldingController, foldingController.isLineHidden(nextLine.id), nextLine.index < lineManager.lineCount - 1 {
            nextLine = lineManager.line(atRow: nextLine.index + 1)
        }
        return locationForMovingDownwards(lineOffset: remainingLineOffset - 1, fromLocation: location, inLineFragmentAt: 0, of: nextLine)
    }

    private func numberOfLineFragments(in line: DocumentLineNode) -> Int {
        let lineController = lineControllerStorage.getOrCreateLineController(for: line)
        return lineController.numberOfLineFragments
    }
}
