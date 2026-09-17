@preconcurrency import AppKit
import Foundation

/// Resolves `NSEvent`s against a ``Keymap``, including two-step chords (e.g. ⌘K ⌘D).
///
/// A bare prefix chord arms a short window (``chordWindow``); the next event either completes
/// the chord or drops the prefix. Any non-prefix, non-completing event resolves normally.
struct KeymapDispatcher {
    enum Resolution: Equatable {
        /// The event completed (or directly matched) a binding.
        case action(EditorActionID)
        /// The event armed a chord prefix and should be swallowed.
        case pendingChord
        /// No binding matched; caller should fall through to default handling.
        case unhandled
    }

    /// How long a chord prefix stays armed.
    var chordWindow: TimeInterval = 2

    private var pendingPrefix: (chord: KeyChord, timestamp: TimeInterval)?

    /// Whether a chord prefix is currently armed.
    var hasPendingChord: Bool { pendingPrefix != nil }

    mutating func reset() {
        pendingPrefix = nil
    }

    mutating func resolve(event: NSEvent, keymap: Keymap, now: TimeInterval = Date().timeIntervalSince1970) -> Resolution {
        let chord = KeyChord(event: event)

        if let pending = pendingPrefix {
            pendingPrefix = nil
            if now - pending.timestamp < chordWindow,
               let action = keymap.chordedAction(prefix: pending.chord, second: chord) {
                return .action(action)
            }
            // Prefix expired or not completed — fall through and let this event be
            // considered on its own merits below.
        }

        if let action = keymap.action(for: KeyStroke(chord)) {
            return .action(action)
        }

        if keymap.isChordPrefix(chord) {
            pendingPrefix = (chord: chord, timestamp: now)
            return .pendingChord
        }

        return .unhandled
    }
}
