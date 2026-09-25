import Foundation

/// One-release rollback for the deferred keystroke parse handoff (PR 3). When `true`, character
/// inserts take the synchronous `apply` branch again. Not routed through ``MetalActivation``.
public enum PenumbraSyncKeystrokeParse {
    public static let defaultsKey = "PenumbraSyncKeystrokeParse"

    public static var defaultPropertyValue: Bool { false }

    public static func resolved(defaults: Bool?) -> Bool {
        defaults ?? defaultPropertyValue
    }
}
