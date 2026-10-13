import Observation

@Observable
public final class UmbraReload: @unchecked Sendable {
    public static let shared = UmbraReload()
    public var generation = 0
    public func bump() { generation += 1 }
}
