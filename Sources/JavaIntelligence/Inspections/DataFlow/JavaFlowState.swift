import Foundation

/// What the flow analysis knows about a reference: it comes only from `null` literals, `new`,
/// literals and null checks on the way, never from a method's contract.
enum JavaNullness {
    case null
    case nonNull
    /// `null` on some paths and not on others.
    case nullable
    /// No information (a call result, a field, a parameter).
    case unknown

    func joined(with other: JavaNullness) -> JavaNullness {
        if self == other { return self }
        if self == .unknown || other == .unknown { return .unknown }
        return .nullable
    }
}

enum JavaFlowConstant: Equatable {
    case bool(Bool)
    case int(Int)
}

/// Whether a closeable created by `new` has been closed. `none` means untracked: the variable
/// escaped (passed on, returned, stored) or never held a resource.
enum JavaResourceState {
    case none
    case open
    case closed
    case mixed

    func joined(with other: JavaResourceState) -> JavaResourceState {
        if self == other { return self }
        if self == .none || other == .none { return .none }
        return .mixed
    }
}

struct JavaFlowValue {
    var nullness = JavaNullness.unknown
    var constant: JavaFlowConstant?
    var resource = JavaResourceState.none

    func joined(with other: JavaFlowValue) -> JavaFlowValue {
        JavaFlowValue(
            nullness: nullness.joined(with: other.nullness),
            constant: constant == other.constant ? constant : nil,
            resource: resource.joined(with: other.resource)
        )
    }
}

/// The facts known at one point, per local (keyed by the start byte of its declaring identifier).
/// A local that is absent is unknown. A `nil` state elsewhere means the point cannot be reached.
/// A value stored in a local that nothing has read since.
struct JavaPendingStore: Hashable {
    let range: Range<Int>
    let name: String
    /// A declaration's initializer: reported when overwritten, not when the method ends.
    let isInitializer: Bool
}

struct JavaFlowState {
    var values: [Int: JavaFlowValue] = [:]
    /// Per local, the stores that may reach this point with no read since (a union over joined paths).
    var unread: [Int: Set<JavaPendingStore>] = [:]

    func joined(with other: JavaFlowState) -> JavaFlowState {
        var result = JavaFlowState()
        for (key, value) in values {
            if let theirs = other.values[key] { result.values[key] = value.joined(with: theirs) }
        }
        for (key, stores) in unread { result.unread[key] = stores }
        for (key, stores) in other.unread { result.unread[key, default: []].formUnion(stores) }
        return result
    }

    /// Forgets everything about the locals in `keys` (they are assigned somewhere the analysis does not follow).
    func havoc(_ keys: Set<Int>) -> JavaFlowState {
        var copy = self
        for key in keys {
            copy.values.removeValue(forKey: key)
            copy.unread.removeValue(forKey: key)
        }
        return copy
    }

    static func join(_ a: JavaFlowState?, _ b: JavaFlowState?) -> JavaFlowState? {
        switch (a, b) {
        case (nil, nil): return nil
        case (let state?, nil), (nil, let state?): return state
        case (let x?, let y?): return x.joined(with: y)
        }
    }
}
