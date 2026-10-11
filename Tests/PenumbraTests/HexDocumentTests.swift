import Foundation
import HexKit
import XCTest

final class HexDocumentTests: XCTestCase {
    func testEditsMatchAPlainBufferAtEdgesAndAcrossPieces() {
        var document = HexDocument(bytes: Array("abcdefghij".utf8))
        document.overwrite(at: 0, bytes: [0x5A])
        document.overwrite(at: 9, bytes: [0x59])
        document.overwrite(at: 3, bytes: [1, 2])
        document.insert(at: 0, bytes: [9])
        document.insert(at: document.count, bytes: [8])
        document.insert(at: 4, bytes: [7])
        document.delete(at: 0, count: 1)
        document.delete(at: document.count - 1, count: 1)
        document.delete(at: 2, count: 4)
        var oracle = Array("abcdefghij".utf8)
        oracle[0] = 0x5A
        oracle[9] = 0x59
        oracle.replaceSubrange(3..<5, with: [1, 2])
        oracle.insert(9, at: 0)
        oracle.append(8)
        oracle.insert(7, at: 4)
        oracle.removeFirst()
        oracle.removeLast()
        oracle.removeSubrange(2..<6)
        XCTAssertEqual(document.bytes(in: 0..<document.count), oracle)
    }

    func testSeededRandomEditsMatchAPlainBuffer() {
        var rng = SplitMix64(seed: 0xC0FFEE)
        var oracle = [UInt8](repeating: 0, count: 32)
        var document = HexDocument(bytes: oracle)
        for _ in 0..<10_000 {
            let operation = rng.next() % 3
            let location = oracle.isEmpty ? 0 : Int(rng.next() % UInt64(oracle.count))
            switch operation {
            case 0:
                let count = min(1 + Int(rng.next() % 4), oracle.count - location)
                guard count > 0 else { continue }
                let bytes = (0..<count).map { _ in UInt8(rng.next() & 0xFF) }
                oracle.replaceSubrange(location..<(location + count), with: bytes)
                document.overwrite(at: Int64(location), bytes: bytes)
            case 1:
                let count = 1 + Int(rng.next() % 3)
                guard oracle.count + count <= 240 else { continue }
                let bytes = (0..<count).map { _ in UInt8(rng.next() & 0xFF) }
                oracle.insert(contentsOf: bytes, at: location)
                document.insert(at: Int64(location), bytes: bytes)
            default:
                let count = min(1 + Int(rng.next() % 4), oracle.count - location)
                guard count > 0 else { continue }
                oracle.removeSubrange(location..<(location + count))
                document.delete(at: Int64(location), count: Int64(count))
            }
        }
        XCTAssertEqual(document.bytes(in: 0..<document.count), oracle)
        XCTAssertEqual(document.count, Int64(oracle.count))
    }

    func testAnEditDoesNotReadTheWholeFile() {
        let original = [UInt8](repeating: 7, count: 50_000)
        let recording = RecordingByteSource(MemoryByteSource(original))
        var document = HexDocument(source: recording)
        recording.reset()
        document.overwrite(at: 100, bytes: [1, 2, 3, 4])
        XCTAssertLessThanOrEqual(recording.bytesRequested, 4)
        XCTAssertLessThan(recording.maxEnd, 200)
        XCTAssertNotEqual(recording.bytesRequested, Int64(original.count))
    }

    func testUndoRedoAndCoalescing() {
        var document = HexDocument(bytes: [10, 20, 30, 40])
        let start = ContinuousClock.now
        document.overwrite(at: 1, bytes: [21], coalescable: true, now: start)
        document.overwrite(at: 2, bytes: [31], coalescable: true, now: start.advanced(by: .milliseconds(200)))
        XCTAssertEqual(document.bytes(in: 0..<4), [10, 21, 31, 40])
        XCTAssertTrue(document.undo())
        XCTAssertEqual(document.bytes(in: 0..<4), [10, 20, 30, 40])
        XCTAssertFalse(document.isModified)
        XCTAssertTrue(document.redo())
        XCTAssertEqual(document.bytes(in: 0..<4), [10, 21, 31, 40])

        document.overwrite(at: 0, bytes: [1], coalescable: true, now: start.advanced(by: .seconds(2)))
        XCTAssertTrue(document.undo())
        XCTAssertEqual(document.bytes(in: 0..<4), [10, 21, 31, 40])
    }

    func testUndoBoundKeepsTheDirtyCounter() {
        var document = HexDocument(bytes: [0])
        let start = ContinuousClock.now
        for index in 0..<1_001 {
            document.overwrite(
                at: 0,
                bytes: [UInt8((index + 1) & 0xFF)],
                now: start.advanced(by: .seconds(Double(index + 1)))
            )
        }
        XCTAssertEqual(document.changedByteCount, 1_001)
        var undos = 0
        while document.undo() { undos += 1 }
        XCTAssertEqual(undos, 1_000)
        XCTAssertTrue(document.isModified)
        XCTAssertEqual(document.changedByteCount, 1)
        XCTAssertNotEqual(document.bytes(in: 0..<1), [0])
    }

    /// A save flattens the snapshot. Appended steps replay onto that file. A log that is no longer
    /// a prefix — the oldest step was dropped — keeps the live piece table instead.
    func testRebaseReplaysAPrefixAndKeepsLiveBytesWhenTheOldestStepWasDropped() {
        var prefixed = HexDocument(bytes: [0x01, 0x02, 0x03, 0x04])
        prefixed.insert(at: 0, bytes: [0xAA])
        let prefixedSnapshot = prefixed.snapshot()
        prefixed.overwrite(at: 2, bytes: [0xBB])
        XCTAssertTrue(prefixed.undoLogExtends(prefixedSnapshot))
        let prefixedFile = MemoryByteSource(prefixedSnapshot.bytes(in: 0..<prefixedSnapshot.count))
        let replayed = prefixed.rebased(onto: prefixedFile, identity: nil, baseline: prefixedSnapshot)
        XCTAssertEqual(replayed.bytes(in: 0..<4), [0xAA, 0x01, 0xBB, 0x03])
        XCTAssertTrue(replayed.isModified)
        XCTAssertFalse(replayed.sharesStorage(with: prefixed))

        let limit = HexUndoStack.limit
        let keystroke = Int64(limit) * 2 + 4
        var document = HexDocument(bytes: [UInt8](repeating: 0, count: limit * 2 + 16))
        let start = ContinuousClock.now
        for index in 0..<limit {
            document.overwrite(
                at: Int64(index) * 2,
                bytes: [0x11],
                now: start.advanced(by: .seconds(Double(index + 1)))
            )
        }
        let snapshot = document.snapshot()
        XCTAssertTrue(document.sharesStorage(with: snapshot))
        document.overwrite(at: keystroke, bytes: [0xAB], now: start.advanced(by: .seconds(Double(limit + 2))))
        XCTAssertFalse(document.undoLogExtends(snapshot))
        XCTAssertEqual(snapshot.byte(at: 0), 0x11)
        XCTAssertEqual(snapshot.byte(at: keystroke), 0x00)
        let flattened = MemoryByteSource(snapshot.bytes(in: 0..<snapshot.count))
        let kept = document.rebased(onto: flattened, identity: nil, baseline: snapshot)
        XCTAssertTrue(kept.sharesStorage(with: document))
        XCTAssertEqual(kept.byte(at: 0), 0x11)
        XCTAssertEqual(kept.byte(at: 1), 0x00)
        XCTAssertEqual(kept.byte(at: keystroke), 0xAB)
        XCTAssertTrue(kept.isModified)
    }

    func testAlreadyDirtyDocumentHasNoUndoStep() {
        var document = HexDocument.unsaved([4, 5], changedBytes: 2)
        XCTAssertTrue(document.isModified)
        XCTAssertEqual(document.changedByteCount, 2)
        XCTAssertFalse(document.undo())
        XCTAssertTrue(document.isModified)
    }

    func testGoToOffsetBookmarksAndDiskCompare() throws {
        XCTAssertEqual(HexGoTo.resolve("0x1F40", caret: 0, count: 10_000), 0x1F40)
        XCTAssertEqual(HexGoTo.resolve("8000", caret: 0, count: 10_000), 8000)
        XCTAssertEqual(HexGoTo.resolve("+0x20", caret: 100, count: 10_000), 132)
        XCTAssertEqual(HexGoTo.resolve("-16", caret: 100, count: 10_000), 84)
        XCTAssertEqual(HexGoTo.resolve("end", caret: 0, count: 40), 40)
        XCTAssertEqual(HexGoTo.resolve("-1000", caret: 4, count: 40), 0)
        XCTAssertNil(HexGoTo.resolve("nope", caret: 0, count: 10))

        var marks = HexBookmarks()
        marks.toggle(8)
        marks.toggle(8)
        XCTAssertEqual(marks.offsets, [])
        for offset in 0..<300 { marks.toggle(Int64(offset)) }
        XCTAssertEqual(marks.offsets.count, HexBookmarks.limit)

        var document = HexDocument(bytes: [1, 2, 3, 4, 5, 6, 7, 8])
        document.overwrite(at: 3, bytes: [9, 9])
        let disk = MemoryByteSource([1, 2, 3, 4, 5, 6, 7, 8])
        let ranges = try HexDiskCompare.differingRanges(document: document, disk: disk).map(\.range)
        XCTAssertEqual(ranges, [3..<5])
    }

    func testRowMathAndHitTesting() {
        XCTAssertEqual(HexLayout.rowCount(byteCount: 0, bytesPerRow: 16), 0)
        XCTAssertEqual(HexLayout.rowCount(byteCount: 1, bytesPerRow: 16), 1)
        XCTAssertEqual(HexLayout.rowCount(byteCount: 15, bytesPerRow: 16), 1)
        XCTAssertEqual(HexLayout.rowCount(byteCount: 16, bytesPerRow: 16), 1)
        XCTAssertEqual(HexLayout.rowCount(byteCount: 17, bytesPerRow: 16), 2)
        let huge = Int64(Int32.max) + 1
        XCTAssertEqual(HexLayout.rowCount(byteCount: huge, bytesPerRow: 16), (huge + 15) / 16)

        let metrics = HexRowMetrics(bytesPerRow: 16, groupSize: 8, charWidth: 10, offsetDigits: 8)
        let first = metrics.hitTest(x: metrics.hexX(byte: 0) + 1)
        XCTAssertEqual(first, HexHit(byteIndex: 0, pane: .hex(lowNibble: false)))
        let low = metrics.hitTest(x: metrics.hexX(byte: 0) + 12)
        XCTAssertEqual(low, HexHit(byteIndex: 0, pane: .hex(lowNibble: true)))
        let text = metrics.hitTest(x: metrics.textX(byte: 3) + 1)
        XCTAssertEqual(text, HexHit(byteIndex: 3, pane: .text))

        let rows = HexLayout.rowCount(byteCount: 4 << 30, bytesPerRow: 16)
        let top = HexScrollerMap.topRow(fraction: 0.5, visibleRows: 40, totalRows: rows)
        XCTAssertEqual(top, (rows - 40) / 2)
        XCTAssertEqual(HexScrollerMap.topRow(fraction: 0, visibleRows: 40, totalRows: rows), 0)
        XCTAssertEqual(HexScrollerMap.topRow(fraction: 1, visibleRows: 40, totalRows: rows), rows - 40)
    }
}

private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

private extension ContinuousClock.Instant {
    func advanced(by duration: Duration) -> ContinuousClock.Instant { self + duration }
}
