@preconcurrency import AppKit

/// A single key press: a key token plus the modifier keys held with it.
///
/// The key is stored either as a lowercased character (matched against
/// `NSEvent.charactersIgnoringModifiers`) or as a hardware key code — the latter for keys
/// that produce no stable character, such as the arrows, Escape, Tab and Return.
public struct KeyChord: Hashable, Sendable {
    /// Modifier keys, restricted to the four that matter for editor shortcuts.
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let control = Modifiers(rawValue: 1 << 2)
        public static let shift = Modifiers(rawValue: 1 << 3)

        /// Narrows raw AppKit flags down to the four editor modifiers.
        public init(_ flags: NSEvent.ModifierFlags) {
            var result: Modifiers = []
            let masked = flags.intersection(.deviceIndependentFlagsMask)
            if masked.contains(.command) { result.insert(.command) }
            if masked.contains(.option) { result.insert(.option) }
            if masked.contains(.control) { result.insert(.control) }
            if masked.contains(.shift) { result.insert(.shift) }
            self = result
        }

        /// Canonical macOS ordering: Control, Option, Shift, Command.
        public var displayString: String {
            var result = ""
            if contains(.control) { result += "\u{2303}" }
            if contains(.option) { result += "\u{2325}" }
            if contains(.shift) { result += "\u{21E7}" }
            if contains(.command) { result += "\u{2318}" }
            return result
        }
    }

    public enum Key: Hashable, Sendable {
        case character(String)
        case code(UInt16)
    }

    public let key: Key
    public let modifiers: Modifiers

    public init(key: Key, modifiers: Modifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    /// Character-keyed chord, e.g. `KeyChord("a", [.command, .shift])` for ⌘⇧A.
    public init(_ character: String, _ modifiers: Modifiers = []) {
        self.key = .character(character.lowercased())
        self.modifiers = modifiers
    }

    /// Key-code-keyed chord, e.g. `KeyChord(code: 0x7E, [.option])` for ⌥↑.
    public init(code: UInt16, _ modifiers: Modifiers = []) {
        self.key = .code(code)
        self.modifiers = modifiers
    }

    /// The chord an event represents, using its character when one is available and falling
    /// back to the key code otherwise. `characterKeys` lists the codes that should still be
    /// matched by character even though AppKit also reports a usable character for them.
    public init(event: NSEvent) {
        self.modifiers = Modifiers(event.modifierFlags)
        if let characters = event.charactersIgnoringModifiers?.lowercased(),
           characters.count == 1,
           let scalar = characters.unicodeScalars.first,
           !CharacterSet.controlCharacters.contains(scalar),
           // AppKit reports arrows / F-keys / Home / End as code points in the
           // private-use function-key block; those are matched by key code instead.
           !(0xF700...0xF8FF).contains(scalar.value),
           scalar != " " {
            self.key = .character(characters)
        } else {
            self.key = .code(event.keyCode)
        }
    }

    public var displayString: String {
        modifiers.displayString + Self.keyDisplayString(key)
    }

    private static func keyDisplayString(_ key: Key) -> String {
        switch key {
        case .character(let value):
            return value.uppercased()
        case .code(let code):
            switch code {
            case 0x7B: return "\u{2190}"
            case 0x7C: return "\u{2192}"
            case 0x7D: return "\u{2193}"
            case 0x7E: return "\u{2191}"
            case 0x24: return "\u{21A9}"
            case 0x30: return "\u{21E5}"
            case 0x35: return "\u{238B}"
            case 0x33: return "\u{232B}"
            case 0x75: return "\u{2326}"
            case 0x31: return "Space"
            default: return "#\(code)"
            }
        }
    }
}
