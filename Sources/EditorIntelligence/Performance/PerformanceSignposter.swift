import os

/// Instruments intervals and events under one subsystem: the only signpost wrapper (F29).
///
/// `EditorIntelligence` cannot use `Penumbra`'s signposter (the layering runs the other way), so each
/// layer makes its own channel from this type and keeps its own subsystem name, which is what Instruments
/// filters on. `PenumbraSignposts` is the `"Penumbra"` channel; ``editorIntelligence`` is this module's.
public struct PerformanceSignposter: Sendable {
    public let signposter: OSSignposter

    public init(subsystem: String, category: String = "Performance") {
        signposter = OSSignposter(subsystem: subsystem, category: category)
    }

    /// The EIP services' intervals (indexing, LSP workspace sync).
    public static let editorIntelligence = PerformanceSignposter(subsystem: "EditorIntelligence")

    @inline(__always)
    public func interval<T>(_ name: StaticString, _ work: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try work()
    }

    @inline(__always)
    public func interval<T>(_ name: StaticString, _ work: () async throws -> T) async rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try await work()
    }

    @inline(__always)
    public func event(_ name: StaticString) {
        signposter.emitEvent(name)
    }
}
