import Metal
import XCTest
@testable import Penumbra

/// F-13: instance-buffer slots never block the calling thread. When every slot is still in
/// flight the write is dropped (`false`) and the caller retries; a reintroduced wait would
/// hang these tests (caught by the runner timeout) instead of failing fast.
@MainActor
final class InstanceSlotTests: XCTestCase {
    func testPageBucketDropsInsteadOfBlockingWhenAllSlotsInFlight() throws {
        let (device, queue) = try requireMetalDevice()
        let bucket = try XCTUnwrap(makeBucket(device: device))
        // Occupy all three slots with command buffers that are never committed, so no
        // completion handler can ever free them.
        var held: [MTLCommandBuffer] = []
        for _ in 0 ..< 3 {
            XCTAssertTrue(bucket.advanceForWrite())
            let buffer = try XCTUnwrap(queue.makeCommandBuffer())
            bucket.markCurrentInFlight(on: buffer)
            held.append(buffer)
        }
        XCTAssertFalse(bucket.canAcquireWriteSlot())
        let start = Date()
        XCTAssertFalse(bucket.advanceForWrite(), "a full bucket must drop, not wait")
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertEqual(held.count, 3)
    }

    func testFreedSlotIsWritableAfterCompletion() throws {
        let (device, queue) = try requireMetalDevice()
        let bucket = try XCTUnwrap(makeBucket(device: device))
        XCTAssertTrue(bucket.advanceForWrite())
        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        bucket.markCurrentInFlight(on: buffer)
        buffer.commit()
        let deadline = Date().addingTimeInterval(5)
        while !bucket.canAcquireWriteSlot(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(bucket.canAcquireWriteSlot(), "committed buffer must free its slot")
        XCTAssertTrue(bucket.advanceForWrite())
    }

    func testDecorationBufferDropsInsteadOfBlockingWhenAllSlotsInFlight() throws {
        let (device, queue) = try requireMetalDevice()
        // Stride matches the item type so a successful write never over-reads its items.
        let buffer = MetalRenderer.DecorationBuffer(device: device, stride: MemoryLayout<UInt64>.stride)
        // Non-empty writes pin their slot via `markCurrentInFlight` (an empty write has a
        // count of zero, so there is nothing to protect and the slot stays free).
        var held: [MTLCommandBuffer] = []
        for _ in 0 ..< 3 {
            XCTAssertTrue(buffer.write([UInt64(1)]))
            let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
            buffer.markCurrentInFlight(on: commandBuffer)
            held.append(commandBuffer)
        }
        let start = Date()
        XCTAssertFalse(buffer.write([UInt64(2)]), "a full buffer must drop, not wait")
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertEqual(held.count, 3)
    }
}

private extension InstanceSlotTests {
    func requireMetalDevice() throws -> (MTLDevice, MTLCommandQueue) {
        guard MetalContext.isAvailable else {
            throw XCTSkip("Metal is not available")
        }
        guard let device = MetalContext.shared.device,
              let queue = MetalContext.shared.commandQueue
        else {
            throw XCTSkip("Metal device or command queue is nil")
        }
        return (device, queue)
    }

    func makeBucket(device: MTLDevice) throws -> MetalRenderer.PageBucket? {
        let buffers = [
            GlyphInstanceBuffer(device: device),
            GlyphInstanceBuffer(device: device),
            GlyphInstanceBuffer(device: device),
        ]
        guard buffers.allSatisfy({ $0 != nil }) else {
            return nil
        }
        return MetalRenderer.PageBucket(buffers: buffers.compactMap { $0 })
    }
}
