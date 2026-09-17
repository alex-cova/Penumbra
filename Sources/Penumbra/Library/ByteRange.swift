import Foundation

struct ByteRange: Hashable {
    let location: ByteCount
    let length: ByteCount
    var lowerBound: ByteCount {
        location
    }
    var upperBound: ByteCount {
        location + length
    }
    var isEmpty: Bool {
        length == 0
    }

    init(location: ByteCount, length: ByteCount) {
        self.location = location
        self.length = length
    }

    init(from startByte: ByteCount, to endByte: ByteCount) {
        self.location = startByte
        self.length = endByte - startByte
    }

    init(utf16Range: NSRange) {
        self.location = ByteCount(utf16Range.location * 2)
        self.length = ByteCount(utf16Range.length * 2)
    }

    func overlaps(_ otherRange: Self) -> Bool {
        let r1 = location ... location + length
        let r2 = otherRange.location ... otherRange.location + otherRange.length
        return r1.overlaps(r2)
    }

    func contains(_ otherRange: Self) -> Bool {
        otherRange.lowerBound >= lowerBound && otherRange.upperBound <= upperBound
    }

    func padded(by pad: ByteCount, within limits: ByteRange) -> ByteRange {
        let startValue = max(limits.lowerBound.value, location.value - pad.value)
        let endValue = min(limits.upperBound.value, upperBound.value + pad.value)
        let start = ByteCount(max(0, startValue))
        let end = ByteCount(max(start.value, endValue))
        return ByteRange(from: start, to: end)
    }
}

extension ByteRange: CustomStringConvertible {
    var description: String {
        "{\(location), \(length)}"
    }
}

extension ByteRange: CustomDebugStringConvertible {
    var debugDescription: String {
        "{\(location), \(length)}"
    }
}
