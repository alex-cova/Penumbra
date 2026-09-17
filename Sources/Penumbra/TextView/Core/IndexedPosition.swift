import Foundation
@preconcurrency import AppKit

final class IndexedPosition: UITextPosition, @unchecked Sendable {
    let index: Int

    init(index: Int) {
        self.index = index
    }
}
