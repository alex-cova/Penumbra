import Foundation
import Metal
import simd

/// One coverage or color glyph quad in content coordinates.
struct GlyphInstance {
    /// Content-space top-left of the padded quad, in points.
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var uvOrigin: SIMD2<Float>
    var uvSize: SIMD2<Float>
    /// Premultiplied sRGB. Alpha includes focus dimming.
    var color: SIMD4<Float>
    var atlasPage: UInt32
}

extension GlyphInstance: Equatable, Sendable {}

/// Shared-storage instance buffer. Grows 16k → 128k by doubling; `compact()` returns to 16k.
/// `count` is the number of instances copied to GPU memory. Overflow past 128k uses extra buffers
/// so glyphs are not dropped. Draw `metalBuffer` with `instanceCount: primaryCount`, not `count`.
@MainActor
final class GlyphInstanceBuffer {
    nonisolated static let minimumCapacity = 16_384
    nonisolated static let maximumCapacity = 131_072

    private let device: MTLDevice
    private(set) var metalBuffer: MTLBuffer
    private(set) var overflowBuffers: [MTLBuffer] = []
    private(set) var capacity: Int
    /// Instances copied into `metalBuffer` + `overflowBuffers`.
    private(set) var count = 0
    /// Instances in `metalBuffer`. Use this as `instanceCount` when drawing the primary buffer.
    private(set) var primaryCount = 0
    /// Last `write` payload. Not truncated when `count` exceeds `maximumCapacity`.
    private(set) var instances: [GlyphInstance] = []

    init?(device: MTLDevice) {
        self.device = device
        self.capacity = Self.minimumCapacity
        let length = Self.minimumCapacity * MemoryLayout<GlyphInstance>.stride
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
            return nil
        }
        self.metalBuffer = buffer
    }

    func write(_ instances: [GlyphInstance]) {
        self.instances = instances
        overflowBuffers = []
        let needed = Self.capacity(forCount: min(instances.count, Self.maximumCapacity))
        if needed > capacity {
            grow(to: needed)
        }
        let stride = MemoryLayout<GlyphInstance>.stride
        primaryCount = min(instances.count, capacity)
        copy(instances, start: 0, count: primaryCount, to: metalBuffer)
        var copied = primaryCount
        var offset = primaryCount
        while offset < instances.count {
            let remaining = instances.count - offset
            let byteCount = remaining * stride
            guard let extra = device.makeBuffer(length: byteCount, options: .storageModeShared) else {
                break
            }
            copy(instances, start: offset, count: remaining, to: extra)
            overflowBuffers.append(extra)
            copied += remaining
            offset += remaining
        }
        count = copied
    }

    func compact() {
        instances = []
        count = 0
        primaryCount = 0
        overflowBuffers = []
        guard capacity != Self.minimumCapacity else {
            return
        }
        let length = Self.minimumCapacity * MemoryLayout<GlyphInstance>.stride
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
            return
        }
        metalBuffer = buffer
        capacity = Self.minimumCapacity
    }

    nonisolated static func capacity(forCount count: Int) -> Int {
        var capacity = minimumCapacity
        while capacity < count && capacity < maximumCapacity {
            let doubled = capacity * 2
            if doubled <= capacity {
                break
            }
            capacity = doubled
        }
        return min(capacity, maximumCapacity)
    }

    private func grow(to newCapacity: Int) {
        let length = newCapacity * MemoryLayout<GlyphInstance>.stride
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
            return
        }
        metalBuffer = buffer
        capacity = newCapacity
    }

    private func copy(_ instances: [GlyphInstance], start: Int, count: Int, to buffer: MTLBuffer) {
        guard count > 0 else {
            return
        }
        let stride = MemoryLayout<GlyphInstance>.stride
        instances.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else {
                return
            }
            buffer.contents().copyMemory(
                from: base.advanced(by: start * stride),
                byteCount: count * stride
            )
        }
    }
}
