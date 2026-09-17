import Foundation

/// One or two ``KeyChord``s. A two-chord stroke is a prefix chord (e.g. ⌘K) followed by a
/// completing chord (e.g. ⌘D) within a short time window — see ``KeymapDispatcher``.
public struct KeyStroke: Hashable, Sendable {
    public let chords: [KeyChord]

    public init(_ chords: [KeyChord]) {
        precondition(!chords.isEmpty && chords.count <= 2, "A KeyStroke holds one or two chords")
        self.chords = chords
    }

    public init(_ chord: KeyChord) {
        self.chords = [chord]
    }

    public init(_ first: KeyChord, _ second: KeyChord) {
        self.chords = [first, second]
    }

    public var isChorded: Bool { chords.count == 2 }
    public var prefix: KeyChord? { isChorded ? chords[0] : nil }

    public var displayString: String {
        chords.map(\.displayString).joined(separator: " ")
    }
}
