import Foundation

public struct HexDiskDifference: Sendable, Equatable {
    public var range: Range<Int64>
    public init(range: Range<Int64>) { self.range = range }
}

/// Ranges where the document's bytes differ from a byte source, read in bounded chunks.
public enum HexDiskCompare {
    public static func differingRanges(
        document: HexDocument,
        disk: any HexByteSource,
        chunkSize: Int = 64 * 1024,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> [HexDiskDifference] {
        let size = max(1, chunkSize)
        let shared = min(document.count, disk.count)
        var ranges: [Range<Int64>] = []
        var open: Range<Int64>?
        var offset: Int64 = 0
        var left = [UInt8](repeating: 0, count: size)
        var right = [UInt8](repeating: 0, count: size)
        while offset < shared {
            if isCancelled() { throw CancellationError() }
            let want = Int(min(Int64(size), shared - offset))
            let end = offset + Int64(want)
            let gotLeft = left.withUnsafeMutableBytes { document.read(offset..<end, into: $0) }
            let gotRight = try right.withUnsafeMutableBytes { try disk.read(offset..<end, into: $0) }
            let comparable = min(want, gotLeft, gotRight)
            var index = 0
            while index < comparable {
                if left[index] == right[index] {
                    if let run = open {
                        ranges.append(run)
                        open = nil
                    }
                    index += 1
                    continue
                }
                let absolute = offset + Int64(index)
                if var run = open, run.upperBound == absolute {
                    run = run.lowerBound..<(absolute + 1)
                    open = run
                } else {
                    if let run = open { ranges.append(run) }
                    open = absolute..<(absolute + 1)
                }
                index += 1
            }
            if comparable < want {
                let absolute = offset + Int64(comparable)
                open = (open?.lowerBound ?? absolute)..<end
            }
            offset = end
        }
        if document.count != disk.count {
            let start = shared
            let end = max(document.count, disk.count)
            if end > start {
                if var run = open, run.upperBound == start {
                    run = run.lowerBound..<end
                    open = run
                } else {
                    if let run = open { ranges.append(run) }
                    open = start..<end
                }
            }
        }
        if let run = open { ranges.append(run) }
        return ranges.map(HexDiskDifference.init)
    }
}
