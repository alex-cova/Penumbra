import Foundation
import TreeSitter

final class TreeSitterTextRange: Sendable {
    let rawValue: TSRange
    var startPoint: TreeSitterTextPoint {
        TreeSitterTextPoint(row: rawValue.start_point.row, column: rawValue.start_point.column)
    }
    var endPoint: TreeSitterTextPoint {
        TreeSitterTextPoint(row: rawValue.end_point.row, column: rawValue.end_point.column)
    }
    var startByte: ByteCount {
        ByteCount(rawValue.start_byte)
    }
    var endByte: ByteCount {
        ByteCount(rawValue.end_byte)
    }

    init(startPoint: TreeSitterTextPoint, endPoint: TreeSitterTextPoint, startByte: ByteCount, endByte: ByteCount) {
        self.rawValue = TSRange(
            start_point: startPoint.rawValue,
            end_point: endPoint.rawValue,
            start_byte: UInt32(startByte.value),
            end_byte: UInt32(endByte.value))
    }
}

extension TreeSitterTextRange {
    /// The range after `edit`, with the rules of `ts_range_edit`: an end at or after the old end of the
    /// edit moves with it, one inside the edit lands on its new end, one before it stays.
    func applying(_ edit: TreeSitterInputEdit) -> TreeSitterTextRange {
        func moved(_ byte: ByteCount, _ point: TreeSitterTextPoint) -> (ByteCount, TreeSitterTextPoint) {
            if byte >= edit.oldEndByte {
                let newByte = ByteCount(byte.value - edit.oldEndByte.value + edit.newEndByte.value)
                let row = Int(point.row) - Int(edit.oldEndPoint.row) + Int(edit.newEndPoint.row)
                let column = point.row == edit.oldEndPoint.row
                    ? Int(edit.newEndPoint.column) + Int(point.column) - Int(edit.oldEndPoint.column)
                    : Int(point.column)
                return (newByte, TreeSitterTextPoint(row: UInt32(max(row, 0)), column: UInt32(max(column, 0))))
            }
            if byte > edit.startByte {
                return (edit.newEndByte, edit.newEndPoint)
            }
            return (byte, point)
        }
        let start = moved(startByte, startPoint)
        let end = moved(endByte, endPoint)
        return TreeSitterTextRange(startPoint: start.1, endPoint: end.1, startByte: start.0, endByte: end.0)
    }
}

extension TreeSitterTextRange: CustomDebugStringConvertible {
    var debugDescription: String {
        "[TreeSitterTextRange startByte=\(startByte) endByte=\(endByte) startPoint=\(startPoint) endPoint=\(endPoint)]"
    }
}
