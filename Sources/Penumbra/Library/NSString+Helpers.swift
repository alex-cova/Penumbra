import Foundation

extension NSString {
    var byteCount: ByteCount {
        ByteCount(length * 2)
    }

    func getAllBytes(withEncoding encoding: String.Encoding, usedLength: inout Int) -> UnsafePointer<Int8>? {
        let range = NSRange(location: 0, length: length)
        return getBytes(in: range, encoding: encoding, usedLength: &usedLength)
    }

    func getBytes(in range: NSRange, encoding: String.Encoding, usedLength: inout Int) -> UnsafePointer<Int8>? {
        let byteRange = ByteRange(utf16Range: range)
        let buffer = UnsafeMutablePointer<Int8>.allocate(capacity: byteRange.length.value)
        let didGetBytes = getBytes(
            buffer,
            maxLength: byteRange.length.value,
            usedLength: &usedLength,
            encoding: encoding.rawValue,
            options: [],
            range: range,
            remaining: nil)
        if didGetBytes {
            return UnsafePointer<Int8>(buffer)
        } else {
            return nil
        }
    }

    /// A wrapper around `rangeOfComposedCharacterSequences(for:)` that considers CRLF line endings as composed character sequences.
    func customRangeOfComposedCharacterSequence(at location: Int) -> NSRange {
        let range = NSRange(location: location, length: 0)
        return customRangeOfComposedCharacterSequences(for: range)
    }

    /// A wrapper around `rangeOfComposedCharacterSequences(for:)` that considers CRLF line endings as composed character sequences.
    func customRangeOfComposedCharacterSequences(for range: NSRange) -> NSRange {
        var result = rangeOfComposedCharacterSequences(for: range)
        let backwardCRLF = NSRange(location: result.location - 1, length: 2)
        if backwardCRLF.location >= 0 && backwardCRLF.upperBound <= length && isCRLFLineEnding(in: backwardCRLF) {
            result = NSRange(location: result.location - 1, length: result.length + 1)
        }
        let forwardCRLF = NSRange(location: result.location, length: 2)
        if forwardCRLF.upperBound <= length && isCRLFLineEnding(in: forwardCRLF) {
            result = NSRange(location: result.location, length: max(result.length, 2))
        }
        return result
    }
}

private extension NSString {
    private func isCRLFLineEnding(in range: NSRange) -> Bool {
        substring(with: range) == Symbol.carriageReturnLineFeed
    }
}
