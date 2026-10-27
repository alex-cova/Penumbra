import Foundation
import GhosttyVt

/// One key press/release/repeat as the view reports it: a physical key, the
/// held modifiers, and the layout-produced text (`NSEvent.characters`), plus
/// the unmodified text (`charactersIgnoringModifiers`) that disambiguates
/// shifted keys.
struct GhosttyKeystroke: Sendable {
    /// macOS virtual key code (`NSEvent.keyCode`), mapped via `GhosttyKeyMap`.
    var keyCode: UInt16
    var modifiers: GhosttyModifiers = []
    /// Layout-produced text, e.g. "a", "A", "\r", "\u{3}". May be empty for
    /// pure modifier presses.
    var text: String = ""
    /// Text without modifiers, for `unshifted_codepoint`. Defaults to `text`.
    var unshiftedText: String?
    var isRepeat: Bool = false
    var isRelease: Bool = false
    var isComposing: Bool = false
}

/// Encodes keystrokes into VT byte sequences using libghostty-vt's key
/// encoder (legacy, application-cursor, Kitty-keyboard and
/// modifyOtherKeys behavior all follow the terminal's live modes).
///
/// Queue affinity: the C encoder and terminal are not thread-safe. Create
/// one per `GhosttyVtTerminal` and touch it only on that terminal's queue
/// (via `GhosttyVtTerminal.withTerminal`), syncing modes first with
/// `syncToTerminal`.
final class GhosttyKeystrokeEncoder {
    private var encoder: GhosttyKeyEncoder?

    init?() {
        var enc: GhosttyKeyEncoder?
        guard ghostty_key_encoder_new(nil, &enc) == GHOSTTY_SUCCESS, let enc else { return nil }
        encoder = enc
    }

    deinit {
        if let encoder { ghostty_key_encoder_free(encoder) }
    }

    /// Refreshes cursor-key/keypad/Kitty/modifyOtherKeys modes from the
    /// terminal, then applies Umbra's Option-as-Meta preference on top
    /// (`setopt_from_terminal` always resets it to false).
    func syncToTerminal(_ terminal: GhosttyTerminal?, optionAsMeta: Bool) {
        guard let encoder, let terminal else { return }
        ghostty_key_encoder_setopt_from_terminal(encoder, terminal)
        var asAlt = optionAsMeta ? GHOSTTY_OPTION_AS_ALT_TRUE : GHOSTTY_OPTION_AS_ALT_FALSE
        ghostty_key_encoder_setopt(encoder, GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, &asAlt)
    }

    /// Encodes one keystroke. Returns nil when the keystroke produces no
    /// output (e.g. a lone modifier press), never for regular keys.
    func encode(_ keystroke: GhosttyKeystroke) -> Data? {
        guard let encoder else { return nil }
        var event: GhosttyKeyEvent?
        guard ghostty_key_event_new(nil, &event) == GHOSTTY_SUCCESS, let event else { return nil }
        defer { ghostty_key_event_free(event) }

        ghostty_key_event_set_action(
            event,
            keystroke.isRelease ? GHOSTTY_KEY_ACTION_RELEASE
                : keystroke.isRepeat ? GHOSTTY_KEY_ACTION_REPEAT : GHOSTTY_KEY_ACTION_PRESS)
        ghostty_key_event_set_key(event, GhosttyKeyMap.key(forKeyCode: keystroke.keyCode))
        ghostty_key_event_set_mods(event, keystroke.modifiers.rawValue)
        ghostty_key_event_set_composing(event, keystroke.isComposing)
        let unshifted = keystroke.unshiftedText ?? keystroke.text
        if let scalar = unshifted.unicodeScalars.first {
            ghostty_key_event_set_unshifted_codepoint(event, scalar.value)
        }

        // set_utf8 borrows the pointer (no copy): the bytes must outlive
        // encode, so they live in this scope. C0 controls, DEL and macOS
        // PUA function-key codes pass as NULL and let the logical key
        // drive the encoding.
        let textBytes: [CChar] = Self.transferBytes(for: keystroke.text)
        return textBytes.withUnsafeBufferPointer { textPtr in
            ghostty_key_event_set_utf8(event, textPtr.baseAddress, textPtr.count)

            var stack = [CChar](repeating: 0, count: 256)
            var written = 0
            let result: GhosttyResult = stack.withUnsafeMutableBufferPointer { ptr in
                ghostty_key_encoder_encode(encoder, event, ptr.baseAddress, ptr.count, &written)
            }
            if result == GHOSTTY_OUT_OF_SPACE {
                var heap = [CChar](repeating: 0, count: written)
                let retry: GhosttyResult = heap.withUnsafeMutableBufferPointer { ptr in
                    ghostty_key_encoder_encode(encoder, event, ptr.baseAddress, ptr.count, &written)
                }
                guard retry == GHOSTTY_SUCCESS else { return nil }
                return Data(heap.prefix(written).map { UInt8(bitPattern: $0) })
            }
            guard result == GHOSTTY_SUCCESS, written > 0 else { return nil }
            return Data(stack.prefix(written).map { UInt8(bitPattern: $0) })
        }
    }

    /// Transfer bytes for `set_utf8`, or empty (NULL) when the text must be
    /// derived from the logical key: C0 controls, DEL, PUA function-key
    /// codes, and empty text.
    private static func transferBytes(for text: String) -> [CChar] {
        guard !text.isEmpty, text.unicodeScalars.allSatisfy({ scalar in
            let v = scalar.value
            return v >= 0x20 && v != 0x7F && !(0xF700...0xF8FF).contains(v)
        }) else { return [] }
        return Array(text.utf8CString.dropLast())
    }
}
