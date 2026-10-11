import Darwin
import Foundation
import HexKit
import XCTest

final class HexWriterTests: XCTestCase {
    private var urls: [URL] = []

    override func tearDown() {
        for url in urls { try? FileManager.default.removeItem(at: url) }
        urls = []
        super.tearDown()
    }

    func testRoundTripWithAndWithoutEditsPreservesMode() throws {
        let url = try makeFile(Data([1, 2, 3, 4, 5]), mode: 0o640)
        let identity = try HexFileIdentity.capture(url: url)
        let clean = HexDocument(source: try FileByteSource(url: url), identity: identity)
        try HexWriter.save(clean, to: url, expected: identity)
        XCTAssertEqual(try Data(contentsOf: url), Data([1, 2, 3, 4, 5]))
        XCTAssertEqual(fileMode(url) & 0o777, 0o640)

        var edited = HexDocument(bytes: [1, 2, 3, 4, 5])
        edited.overwrite(at: 1, bytes: [9, 8])
        edited.insert(at: 5, bytes: [7])
        let again = try HexFileIdentity.capture(url: url)
        try HexWriter.save(edited, to: url, expected: again)
        XCTAssertEqual(try Data(contentsOf: url), Data([1, 9, 8, 4, 5, 7]))
        XCTAssertEqual(fileMode(url) & 0o777, 0o640)
    }

    func testCancelAndChangedOnDiskLeaveTheTargetUntouched() throws {
        let url = try makeFile(Data([4, 5, 6]), mode: 0o644)
        let identity = try HexFileIdentity.capture(url: url)
        let cancel = HexWriteCancellation()
        cancel.cancel()
        XCTAssertThrowsError(try HexWriter.save(HexDocument(bytes: [1]), to: url, expected: identity, cancellation: cancel)) { error in
            XCTAssertEqual(error as? HexWriteError, .cancelled)
        }
        XCTAssertEqual(try Data(contentsOf: url), Data([4, 5, 6]))

        try Data([9]).write(to: url)
        XCTAssertThrowsError(try HexWriter.save(HexDocument(bytes: [1, 1]), to: url, expected: identity)) { error in
            XCTAssertEqual(error as? HexWriteError, .changedOnDisk)
        }
        XCTAssertEqual(try Data(contentsOf: url), Data([9]))
        let forced = try HexFileIdentity.capture(url: url)
        try HexWriter.save(HexDocument(bytes: [3, 3]), to: url, expected: identity, overwriteChanged: true)
        XCTAssertEqual(try Data(contentsOf: url), Data([3, 3]))
        _ = forced
    }

    func testSparseFileRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hex-sparse-\(UUID().uuidString)")
        urls.append(url)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let fd = Darwin.open(url.path, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        let size: off_t = 64 * 1024 * 1024
        XCTAssertEqual(ftruncate(fd, size), 0)
        var marker: UInt8 = 0x5A
        XCTAssertEqual(pwrite(fd, &marker, 1, size - 1), 1)
        Darwin.close(fd)
        chmod(url.path, 0o600)
        let identity = try HexFileIdentity.capture(url: url)
        var document = HexDocument(source: try FileByteSource(url: url), identity: identity)
        document.overwrite(at: 0, bytes: [0x11])
        try HexWriter.save(document, to: url, expected: identity)
        let saved = try HexFileIdentity.capture(url: url)
        XCTAssertEqual(saved.size, 64 * 1024 * 1024)
        XCTAssertEqual(saved.mode & 0o777, 0o600)
        let source = try FileByteSource(url: url)
        defer { source.close() }
        var head = [UInt8](repeating: 0, count: 1)
        var tail = [UInt8](repeating: 0, count: 1)
        _ = try head.withUnsafeMutableBytes { try source.read(0..<1, into: $0) }
        _ = try tail.withUnsafeMutableBytes { try source.read((source.count - 1)..<source.count, into: $0) }
        XCTAssertEqual(head, [0x11])
        XCTAssertEqual(tail, [0x5A])
    }

    private func makeFile(_ data: Data, mode: mode_t) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hex-write-\(UUID().uuidString)")
        try data.write(to: url)
        chmod(url.path, mode)
        urls.append(url)
        return url
    }

    private func fileMode(_ url: URL) -> UInt32 {
        var info = stat()
        _ = stat(url.path, &info)
        return UInt32(info.st_mode)
    }
}
