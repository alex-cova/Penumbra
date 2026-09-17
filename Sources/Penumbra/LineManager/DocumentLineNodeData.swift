import CoreGraphics
import Foundation

final class DocumentLineNodeData {
    var delimiterLength = 0 {
        didSet {
            assert(delimiterLength >= 0 && delimiterLength <= 2)
        }
    }
    var totalLength = 0
    var length: Int {
        totalLength - delimiterLength
    }
    var lineHeight: CGFloat
    var totalLineHeight: CGFloat = 0
    var nodeTotalByteCount = ByteCount(0)
    var cachedStartByte = ByteCount(0)
    var startByte: ByteCount {
        cachedStartByte
    }
    var byteCount = ByteCount(0)
    var byteRange: ByteRange {
        ByteRange(location: startByte, length: byteCount - ByteCount(delimiterLength))
    }
    var totalByteRange: ByteRange {
        ByteRange(location: startByte, length: byteCount)
    }

    weak var node: DocumentLineNode?

    init(lineHeight: CGFloat) {
        self.lineHeight = lineHeight
    }
}

extension DocumentLineNodeData: CustomDebugStringConvertible {
    var debugDescription: String {
        "[DocumentLineNodeData length=\(length) delimiterLength=\(delimiterLength) totalLength=\(totalLength)]"
    }
}
