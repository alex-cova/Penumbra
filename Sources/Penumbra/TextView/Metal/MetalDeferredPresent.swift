import Foundation

/// Gates the display-link present path. Read beside ``MetalActivation``, not inside
/// ``MetalActivation/resolved(property:deviceAvailable:defaults:)``.
public enum MetalDeferredPresent {
    public static let defaultsKey = "PenumbraMetalDeferredPresent"

    /// Default on after the keystroke-budget pass (PR 6). Use `--no-metal-deferred-present` to roll back.
    public static var defaultPropertyValue: Bool { true }

    public static func resolved(defaults: Bool?) -> Bool {
        defaults ?? defaultPropertyValue
    }
}
