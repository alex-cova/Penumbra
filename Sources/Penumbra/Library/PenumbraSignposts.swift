import os

/// Instruments intervals named in PERFORMANCE_AUDIT.md Phase 5 §4.
enum PenumbraSignposts {
    static let performance = OSSignposter(subsystem: "Penumbra", category: "Performance")

    @inline(__always)
    static func interval<T>(_ name: StaticString, _ work: () throws -> T) rethrows -> T {
        let state = performance.beginInterval(name)
        defer { performance.endInterval(name, state) }
        return try work()
    }

    @inline(__always)
    static func interval<T>(_ name: StaticString, _ work: () async throws -> T) async rethrows -> T {
        let state = performance.beginInterval(name)
        defer { performance.endInterval(name, state) }
        return try await work()
    }

    @inline(__always)
    static func event(_ name: StaticString) {
        performance.emitEvent(name)
    }
}
