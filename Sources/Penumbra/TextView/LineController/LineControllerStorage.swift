import Foundation
@preconcurrency import AppKit
protocol LineControllerStorageDelegate: AnyObject {
    func lineControllerStorage(_ storage: LineControllerStorage, didCreate lineController: LineController)
}

final class LineControllerStorage {
    weak var delegate: LineControllerStorageDelegate?
    subscript(_ lineID: DocumentLineNodeID) -> LineController? {
        lineControllers[lineID]
    }

    var stringView: StringView {
        didSet {
            if stringView !== oldValue {
                lineControllers.removeAll()
            }
        }
    }

    var numberOfLineControllers: Int {
        lineControllers.count
    }

    private var lineControllers: [DocumentLineNodeID: LineController] = [:]
    private let lineControllerFactory: LineControllerFactory

    init(stringView: StringView, lineControllerFactory: LineControllerFactory) {
        self.stringView = stringView
        self.lineControllerFactory = lineControllerFactory
    }

    func getOrCreateLineController(for line: DocumentLineNode) -> LineController {
        if let cachedLineController = lineControllers[line.id] {
            return cachedLineController
        } else {
            let lineController = lineControllerFactory.makeLineController(for: line)
            lineControllers[line.id] = lineController
            delegate?.lineControllerStorage(self, didCreate: lineController)
            return lineController
        }
    }

    func removeLineController(withID lineID: DocumentLineNodeID) {
        lineControllers.removeValue(forKey: lineID)
    }

    func removeAllLineControllers() {
        lineControllers.removeAll()
    }

    /// Once more than `limit` controllers are kept, drops those whose line row is outside
    /// `keptRows`, except `pinnedLineIDs`. A dropped controller is recreated (and re-typeset) the
    /// next time its line is needed. Returns how many were dropped.
    @discardableResult
    func evictLineControllers(ifMoreThan limit: Int,
                              keepingRows keptRows: ClosedRange<Int>,
                              pinnedLineIDs: Set<DocumentLineNodeID> = []) -> Int {
        guard lineControllers.count > limit else {
            return 0
        }
        let countBefore = lineControllers.count
        lineControllers = lineControllers.filter { lineID, lineController in
            keptRows.contains(lineController.line.row) || pinnedLineIDs.contains(lineID)
        }
        return countBefore - lineControllers.count
    }

    func removeAllLineControllers(exceptLinesWithID exceptionLineIDs: Set<DocumentLineNodeID>) {
        let allLineIDs = Set(lineControllers.keys)
        let lineIDsToRelease = allLineIDs.subtracting(exceptionLineIDs)
        for lineID in lineIDsToRelease {
            lineControllers.removeValue(forKey: lineID)
        }
    }
}

extension LineControllerStorage: Sequence {
    struct Iterator: IteratorProtocol {
        private let lineControllers: [LineController]
        private var index = 0

        init(lineControllers: [LineController]) {
            self.lineControllers = lineControllers
        }

        mutating func next() -> LineController? {
            if index < lineControllers.count {
                let lineController = lineControllers[index]
                index += 1
                return lineController
            } else {
                return nil
            }
        }
    }

    func makeIterator() -> Iterator {
        let lineControllers = Array(lineControllers.values)
        return Iterator(lineControllers: lineControllers)
    }
}
