import EditorIntelligence
import os

/// Instruments intervals for the text engine, under the `"Penumbra"` subsystem. The interval logic is
/// `PerformanceSignposter`'s; this keeps the short call-site spelling.
enum PenumbraSignposts {
    static let channel = PerformanceSignposter(subsystem: "Penumbra")
    static var performance: OSSignposter { channel.signposter }

    @inline(__always)
    static func interval<T>(_ name: StaticString, _ work: () throws -> T) rethrows -> T {
        try channel.interval(name, work)
    }

    @inline(__always)
    static func interval<T>(_ name: StaticString, _ work: () async throws -> T) async rethrows -> T {
        try await channel.interval(name, work)
    }

    @inline(__always)
    static func event(_ name: StaticString) {
        channel.event(name)
    }
}
