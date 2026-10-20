import Foundation
import CoreGraphics
import Metal

/// Process-wide Metal bootstrap for Luna's GPU diagram backend.
///
/// Mirrors the `MetalContext` pattern from Penumbra without depending on it:
/// the system default device, one command queue, a lazily compiled shader
/// library, and a permanent-failure latch with a human-readable reason so
/// every caller can fall back to CoreGraphics. All members are safe to use
/// off the main thread; mutable state is held behind a lock.
public final class MetalDiagramBackend {
    public static let shared = MetalDiagramBackend()

    /// Bounds matching the preview's upload guard (16M pixels, BGRA).
    public static let maxPixelCount = 16_777_216
    public static let maxTextureDimension = 16_384

    public static func canAllocate(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        guard width <= maxTextureDimension, height <= maxTextureDimension else { return false }
        guard height <= Int.max / width else { return false }
        return width * height <= maxPixelCount
    }

    private let lock = NSLock()
    private var _device: MTLDevice?
    private var _queue: MTLCommandQueue?
    private var _library: MTLLibrary?
    private var _failed = false

    public private(set) var failureReason: String?

    private init() {
        let device = MTLCreateSystemDefaultDevice()
        _device = device
        _queue = device?.makeCommandQueue()
        if device == nil || _queue == nil {
            _failed = true
            failureReason = "No Metal device or command queue"
        }
    }

    var device: MTLDevice? {
        lock.lock(); defer { lock.unlock() }
        return _failed ? nil : _device
    }

    public var isAvailable: Bool {
        lock.lock(); defer { lock.unlock() }
        guard !_failed, _device != nil, _queue != nil else { return false }
        if _library == nil {
            compileLocked()
        }
        return !_failed && _library != nil
    }

    func withLibrary<T>(_ body: (MTLDevice, MTLCommandQueue, MTLLibrary) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard !_failed, let device = _device, let queue = _queue else {
            throw MetalDiagramError.unavailable(failureReason ?? "Metal unavailable")
        }
        if _library == nil {
            compileLocked()
        }
        guard let library = _library, !_failed else {
            throw MetalDiagramError.unavailable(failureReason ?? "Metal shader compile failed")
        }
        return try body(device, queue, library)
    }

    func markUnavailable(reason: String) {
        lock.lock(); defer { lock.unlock() }
        guard !_failed else { return }
        _failed = true
        failureReason = reason
        _library = nil
    }

    private func compileLocked() {
        guard let device = _device, !_failed else { return }
        do {
            _library = try device.makeLibrary(source: MetalDiagramShaders.source, options: nil)
        } catch {
            _failed = true
            failureReason = "Metal shader compile failed: \(error.localizedDescription)"
            _library = nil
        }
    }
}

public enum MetalDiagramError: Error, LocalizedError {
    case unavailable(String)
    case allocationFailed(String)
    case encodeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message): return "Metal diagram backend unavailable: \(message)"
        case .allocationFailed(let message): return "Metal texture allocation failed: \(message)"
        case .encodeFailed(let message): return "Metal encode failed: \(message)"
        }
    }
}
