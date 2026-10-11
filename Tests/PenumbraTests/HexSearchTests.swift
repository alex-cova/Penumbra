import Foundation
import HexKit
import XCTest

final class HexSearchTests: XCTestCase {
    func testMatchAcrossAChunkBoundaryWildcardsOverlapsAndDirection() throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        bytes.replaceSubrange(6..<10, with: [1, 2, 3, 4])
        let source = MemoryByteSource(bytes)
        let pattern = try XCTUnwrap(HexPattern.hex("01020304"))
        let forward = try HexSearch.scan(in: source, pattern: pattern, chunkSize: 8)
        XCTAssertEqual(forward.matches, [6..<10])

        let wild = try XCTUnwrap(HexPattern.hex("01??0304"))
        XCTAssertEqual(try HexSearch.scan(in: source, pattern: wild, chunkSize: 8).matches, [6..<10])

        let repeats = MemoryByteSource(Array("aaa".utf8))
        let aa = try XCTUnwrap(HexPattern.text("aa", encoding: .ascii, caseInsensitive: false))
        XCTAssertEqual(try HexSearch.scan(in: repeats, pattern: aa).matches.map(\.lowerBound), [0, 1])
        let back = try HexSearch.scan(in: repeats, pattern: aa, from: 3, direction: .backward)
        XCTAssertEqual(back.matches.map(\.lowerBound), [1, 0])
    }

    func testASCIICaseAndUTF16() throws {
        let source = MemoryByteSource(Array("AbC def".utf8))
        let pattern = try XCTUnwrap(HexPattern.text("abc", encoding: .ascii, caseInsensitive: true))
        XCTAssertEqual(try HexSearch.scan(in: source, pattern: pattern).matches, [0..<3])
        let sensitive = try XCTUnwrap(HexPattern.text("abc", encoding: .ascii, caseInsensitive: false))
        XCTAssertTrue(try HexSearch.scan(in: source, pattern: sensitive).matches.isEmpty)

        let units = try XCTUnwrap(HexPattern.text("Ab", encoding: .utf16LE, caseInsensitive: false))
        var encoded: [UInt8] = []
        for unit in "Ab".utf16 {
            encoded.append(UInt8(truncatingIfNeeded: unit))
            encoded.append(UInt8(truncatingIfNeeded: unit >> 8))
        }
        XCTAssertEqual(units.bytes, encoded)
        XCTAssertEqual(try HexSearch.scan(in: MemoryByteSource(encoded + [0, 0]), pattern: units).matches, [0..<4])
    }

    func testLimitDoesNotReadASecondChunk() throws {
        var bytes = [UInt8](repeating: 0, count: 1_000)
        bytes[0] = 9
        let recording = RecordingByteSource(MemoryByteSource(bytes))
        let pattern = HexPattern(bytes: [9])
        let found = try HexSearch.scan(in: recording, pattern: pattern, chunkSize: 16, limit: 1)
        XCTAssertEqual(found.matches, [0..<1])
        XCTAssertTrue(found.capped)
        XCTAssertLessThanOrEqual(recording.maxEnd, 16 + Int64(pattern.bytes.count - 1))
    }

    func testCancellation() async throws {
        let task = Task {
            try HexSearch.scan(
                in: PausingByteSource(count: 2_000_000),
                pattern: HexPattern(bytes: [0xFF]),
                chunkSize: 64 * 1024,
                limit: 1_000_000
            )
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        task.cancel()
        let outcome = await task.result
        guard case let .failure(error) = outcome else {
            XCTFail("search finished")
            return
        }
        XCTAssertTrue(error is CancellationError)
    }
}

private final class PausingByteSource: @unchecked Sendable, HexByteSource {
    let count: Int64
    init(count: Int64) { self.count = count }
    func read(_ range: Range<Int64>, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        try Task.checkCancellation()
        Thread.sleep(forTimeInterval: 0.05)
        let available = min(buffer.count, Int(max(0, range.upperBound - range.lowerBound)))
        if available > 0, let base = buffer.baseAddress { memset(base, 0, available) }
        return available
    }
}
