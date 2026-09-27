import Foundation
@preconcurrency import AppKit

final class IndexedPosition: EditorTextPosition, @unchecked Sendable {
    let index: Int

    init(index: Int) {
        self.index = index
    }
}
