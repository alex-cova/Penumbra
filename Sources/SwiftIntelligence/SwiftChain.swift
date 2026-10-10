import Foundation

/// An expression's access path as written: where it starts and the member accesses, calls and
/// unwraps applied to it. A chain is typed later (`SwiftResolver`), against whatever the index
/// knows, so building one never looks outside the file.
///
/// `items.first!.name(label: 1)` is the base `items` with steps `.member("first")`, `.unwrap`,
/// `.member("name")` and `.call(labels: ["label"])`.
public struct SwiftChain: Sendable, Equatable {
    public enum Base: Sendable, Equatable {
        /// An identifier and where it was written, which decides the binding it names.
        case name(String, at: Int)
        case selfValue
        case superValue
        /// `.red`: a member of a type only the context knows.
        case implicitMember(String)
        /// A value of a type the text states: a literal, a cast, a constructor.
        case instance(String)
        /// A type written in a constructor expression (`Foo<Int>(…)`); its first call makes an instance.
        case metatype(String)
        case unknown
    }

    public enum Step: Sendable, Equatable {
        case member(String)
        /// An application; the labels of its arguments (`"_"` for an unlabelled one).
        case call(labels: [String])
        case subscripted
        case unwrap
    }

    public var base: Base
    public var steps: [Step]

    public static let unknown = SwiftChain(base: .unknown, steps: [])

    /// The identifier at the start, if the chain is just a name.
    public var isBareName: Bool {
        if case .name = base { return steps.isEmpty }
        return false
    }
}
