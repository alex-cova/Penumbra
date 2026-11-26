import Foundation

/// How much of a large value is kept in a result. The rest is fetched on demand by the inspector.
public struct ValueLimits: Sendable, Equatable {
    /// Text, JSON and similar longer than this many bytes are stored as a `.truncated` preview.
    public var maxTextBytes: Int
    /// Binary values keep only this many leading bytes (plus their full length).
    public var binaryPrefix: Int

    public init(maxTextBytes: Int = 65_536, binaryPrefix: Int = 64) {
        self.maxTextBytes = maxTextBytes
        self.binaryPrefix = binaryPrefix
    }

    public static let standard = ValueLimits()

    /// What a decoder reads when the caller does not pass limits. A task can raise it for the
    /// one statement that fetches a single large value (`ValueLimits.$override.withValue`); every
    /// result a user query fills stays on `.standard`.
    @TaskLocal public static var override: ValueLimits?

    public static var current: ValueLimits { override ?? .standard }

    /// The most the inspector ever asks for in one fetch.
    public static let fullValueLimit = 64 * 1_024 * 1_024
}
