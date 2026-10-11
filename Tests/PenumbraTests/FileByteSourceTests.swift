import Darwin
import Foundation
import HexKit
import os
import XCTest

final class FileByteSourceTests: XCTestCase {
    private var urls: [URL] = []

    override func tearDown() {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
        urls = []
        super.tearDown()
    }

    func testReadsAtBoundariesPastEOFAndEmpty() throws {
        let url = try makeFile(Data((0..<100).map { UInt8($0) }))
        let source = try FileByteSource(url: url)
        defer { source.close() }
        XCTAssertEqual(read(source, 0..<4), [0, 1, 2, 3])
        XCTAssertEqual(read(source, 98..<120), [98, 99])
        XCTAssertEqual(read(source, 100..<110), [])
        XCTAssertEqual(read(source, 50..<50), [])

        let emptyURL = try makeFile(Data())
        let empty = try FileByteSource(url: emptyURL)
        defer { empty.close() }
        XCTAssertEqual(empty.count, 0)
        XCTAssertEqual(read(empty, 0..<8), [])
        XCTAssertFalse(empty.isStale)
    }

    func testPageBoundaryAndTruncatedRead() throws {
        var bytes = Data(count: FileByteSource.pageSize + 10)
        bytes[0] = 1
        bytes[1] = 2
        bytes[2] = 3
        bytes[3] = 4
        bytes[FileByteSource.pageSize - 2] = 0xAB
        bytes[FileByteSource.pageSize] = 0xCD
        let url = try makeFile(bytes)
        let source = try FileByteSource(url: url)
        source.allowsReadahead = false
        defer { source.close() }
        let start = Int64(FileByteSource.pageSize - 2)
        XCTAssertEqual(read(source, start..<(start + 4)), [0xAB, 0, 0xCD, 0])
        source.close()

        let truncatedURL = try makeFile(bytes)
        let truncated = try FileByteSource(url: truncatedURL)
        truncated.allowsReadahead = false
        defer { truncated.close() }
        let fd = Darwin.open(truncatedURL.path, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(ftruncate(fd, 4), 0)
        Darwin.close(fd)
        let again = read(truncated, 0..<16)
        XCTAssertEqual(again, [1, 2, 3, 4] + Array(repeating: 0, count: 12))
        XCTAssertTrue(truncated.isStale)
    }

    func testConcurrentReads() throws {
        let url = try makeFile(Data((0..<8_000).map { UInt8($0 & 0xFF) }))
        let source = try FileByteSource(url: url)
        source.allowsReadahead = false
        defer { source.close() }
        let group = DispatchGroup()
        let failures = OSAllocatedUnfairLock(initialState: 0)
        for index in 0..<32 {
            group.enter()
            DispatchQueue.global().async {
                let start = Int64(index * 100)
                let got = read(source, start..<(start + 50))
                let expect = (0..<50).map { UInt8((Int(start) + $0) & 0xFF) }
                if got != expect { failures.withLock { $0 += 1 } }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(failures.withLock { $0 }, 0)
    }

    func testLRUDropsTheOldestPage() throws {
        let pages = FileByteSource.maxCachedPages + 1
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hex-lru-\(UUID().uuidString)")
        urls.append(url)
        let fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_TRUNC, 0o644)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(ftruncate(fd, off_t(pages * FileByteSource.pageSize)), 0)
        Darwin.close(fd)
        let source = try FileByteSource(url: url)
        source.allowsReadahead = false
        defer { source.close() }
        for index in 0..<pages {
            _ = read(source, Int64(index * FileByteSource.pageSize)..<Int64(index * FileByteSource.pageSize + 1))
        }
        XCTAssertLessThanOrEqual(source.cachedPageCount, FileByteSource.maxCachedPages)
        let loads = source.pageLoadCount
        _ = read(source, 0..<1)
        XCTAssertGreaterThan(source.pageLoadCount, loads)
        XCTAssertEqual(FileByteSource.openDescriptorCount > 0, true)
        source.close()
        let after = FileByteSource.openDescriptorCount
        _ = after
    }

    private func makeFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hex-src-\(UUID().uuidString)")
        try data.write(to: url)
        urls.append(url)
        return url
    }
}

private func read(_ source: any HexByteSource, _ range: Range<Int64>) -> [UInt8] {
    let count = Int(max(0, range.upperBound - range.lowerBound))
    guard count > 0 else { return [] }
    var buffer = [UInt8](repeating: 0xFF, count: count)
    let n = (try? buffer.withUnsafeMutableBytes { try source.read(range, into: $0) }) ?? 0
    return Array(buffer.prefix(n))
}
