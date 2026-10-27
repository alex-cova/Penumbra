import AppKit

/// Modifier state for key and mouse events, mirroring the `GHOSTTY_MODS_*`
/// bitmask (`GhosttyMods`, a `UInt16`).
struct GhosttyModifiers: OptionSet, Sendable {
    let rawValue: UInt16

    init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    static let shift   = GhosttyModifiers(rawValue: 1 << 0)
    static let control = GhosttyModifiers(rawValue: 1 << 1)
    static let alt     = GhosttyModifiers(rawValue: 1 << 2)
    static let command = GhosttyModifiers(rawValue: 1 << 3)
    static let capsLock = GhosttyModifiers(rawValue: 1 << 4)
    static let numLock  = GhosttyModifiers(rawValue: 1 << 5)

    init(appKitFlags flags: NSEvent.ModifierFlags) {
        var mods = GhosttyModifiers()
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.option) { mods.insert(.alt) }
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.capsLock) { mods.insert(.capsLock) }
        if flags.contains(.numericPad) { mods.insert(.numLock) }
        self = mods
    }
}
