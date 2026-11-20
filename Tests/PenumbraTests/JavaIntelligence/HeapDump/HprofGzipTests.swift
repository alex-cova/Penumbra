import Foundation
@testable import JavaIntelligence
import XCTest

final class HprofGzipTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("HprofGzipTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// `gzip -c` of `data`, one member.
    private func gzip(_ data: Data) throws -> Data {
        let input = directory.appendingPathComponent("in-\(UUID().uuidString)")
        try data.write(to: input)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c", input.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return output
    }

    private func dumpBytes() -> Data {
        var writer = HprofTestWriter()
        writer.loadClass(0x100, name: "java/lang/Object")
        writer.segment { s in
            s.classDump(0x100)
            for index in 0..<2_000 { s.primitiveArray(UInt64(0x1000 + index * 0x100), type: .int, length: index % 50) }
        }
        return writer.data()
    }

    private func roundTrip(_ compressed: Data) throws -> Data {
        let source = directory.appendingPathComponent("dump.hprof.gz")
        let target = directory.appendingPathComponent("dump.hprof")
        try compressed.write(to: source)
        try HprofGzip.decompress(source, to: target)
        return try Data(contentsOf: target)
    }

    func testOneMember() throws {
        let original = dumpBytes()
        XCTAssertEqual(try roundTrip(try gzip(original)), original)
        XCTAssertTrue(HprofDetector.isHeapDump(head: try Data(contentsOf: directory.appendingPathComponent("dump.hprof"))))
    }

    func testMembersBackToBackAsHotSpotWritesThem() throws {
        let original = dumpBytes()
        let third = original.count / 3
        let parts = [original[..<third], original[third..<(2 * third)], original[(2 * third)...]].map { Data($0) }
        var compressed = Data()
        for part in parts { compressed.append(try gzip(part)) }
        XCTAssertEqual(try roundTrip(compressed), original)
    }

    func testALargeFileAcrossManyBuffers() throws {
        var random = SeededRandom(seed: 42)
        var original = Data(capacity: 6 << 20)
        while original.count < 6 << 20 {
            // Compressible, but not trivially: runs of a few random bytes.
            let byte = UInt8(truncatingIfNeeded: random.next())
            original.append(contentsOf: repeatElement(byte, count: Int(random.next() % 16) + 1))
        }
        XCTAssertEqual(try roundTrip(try gzip(original)), original)
    }

    func testDamageIsReportedAndLeavesNothing() throws {
        let original = dumpBytes()
        var compressed = try gzip(original)
        // Truncated inside the stream.
        XCTAssertThrowsError(try roundTrip(compressed.prefix(compressed.count / 2))) { error in
            guard case HprofGzip.Failure.corrupt = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("dump.hprof").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".dump.hprof.partial").path))
        // A wrong checksum in the trailer.
        compressed[compressed.count - 6] ^= 0xFF
        XCTAssertThrowsError(try roundTrip(compressed)) { error in
            XCTAssertEqual(error as? HprofGzip.Failure, .corrupt("member 1 fails its checksum"))
        }
        // Not gzip at all.
        let plain = directory.appendingPathComponent("plain.hprof")
        try original.write(to: plain)
        XCTAssertFalse(HprofGzip.isGzip(at: plain))
        XCTAssertThrowsError(try HprofGzip.decompress(plain, to: directory.appendingPathComponent("out.hprof"))) { error in
            XCTAssertEqual(error as? HprofGzip.Failure, .notGzip)
        }
    }
}

final class HeapDumpLaunchTests: XCTestCase {
    func testOutOfMemoryDumpsGoToAFolderUnlessAPathIsGiven() {
        let folder = URL(fileURLWithPath: "/tmp/dumps")
        XCTAssertEqual(
            JavaVMOptions.heapDumpPathArguments(vmArguments: "-Xmx64m -XX:+HeapDumpOnOutOfMemoryError", directory: folder),
            ["-XX:HeapDumpPath=/tmp/dumps"]
        )
        XCTAssertEqual(JavaVMOptions.heapDumpPathArguments(
            vmArguments: "-XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/elsewhere", directory: folder
        ), [])
        XCTAssertEqual(JavaVMOptions.heapDumpPathArguments(vmArguments: "-Xmx64m", directory: folder), [])
        XCTAssertEqual(JavaVMOptions.heapDumpPathArguments(vmArguments: "-XX:-HeapDumpOnOutOfMemoryError", directory: folder), [])
    }

    func testJcmdHeapDump() {
        let jcmd = URL(fileURLWithPath: "/jdk/bin/jcmd")
        let file = URL(fileURLWithPath: "/tmp/heap.hprof")
        XCTAssertEqual(JavaLiveCommands.dumpHeap(jcmd: jcmd, pid: 42, file: file, allObjects: false).arguments, ["42", "GC.heap_dump", "/tmp/heap.hprof"])
        XCTAssertEqual(JavaLiveCommands.dumpHeap(jcmd: jcmd, pid: 42, file: file, allObjects: true).arguments, ["42", "GC.heap_dump", "-all", "/tmp/heap.hprof"])
    }
}
