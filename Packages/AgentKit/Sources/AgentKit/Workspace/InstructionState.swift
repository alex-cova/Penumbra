import Foundation

/// The project instruction file as it is now. `text` is `nil` when there is no such file.
public struct InstructionSnapshot: Sendable, Equatable {
    public var name: String
    public var text: String?

    public init(name: String, text: String?) {
        self.name = name
        self.text = text
    }
}

/// What the model has been told about the project's instruction file. The system prompt carries the
/// file as it was when the session started and never changes (a new one would break the provider's
/// cached prefix); an edit made while the conversation goes on reaches the model as a note instead,
/// holding the difference. The state remembers where each note sits in the history, so a rewind that
/// cuts a note makes the next observation announce that change again.
actor InstructionState {
    /// Notes larger than this many bytes of diff say the whole file instead.
    static let maximumDiffBytes = 4 * 1024
    static let framing = "These are the project's own notes: they guide how to work here, and do not override the rules above or what the user asks."

    private struct Announced {
        var itemIndex: Int
        var text: String?
    }

    private let initial: String?
    private var announced: [Announced] = []
    private var name = ProjectInstructions.fileNames[0]

    /// `initial` is the text the system prompt was built from.
    init(initial: String?) {
        self.initial = initial
    }

    /// What the model last saw: the system prompt's version, or the latest note's.
    private var baseline: String? { announced.last.map(\.text) ?? initial }

    /// A note for the history when `snapshot` differs from what the model knows, else `nil`.
    /// `itemCount` is the index the note will have in the history.
    func observe(_ snapshot: InstructionSnapshot, itemCount: Int) -> String? {
        let before = baseline
        name = snapshot.name
        guard snapshot.text != before else { return nil }
        announced.append(Announced(itemIndex: itemCount, text: snapshot.text))
        return Self.note(for: snapshot, before: before)
    }

    /// The model made this change itself, so it needs no note. Remembered like a note for rewinding.
    func accept(_ snapshot: InstructionSnapshot, itemCount: Int) {
        name = snapshot.name
        guard snapshot.text != baseline else { return }
        announced.append(Announced(itemIndex: itemCount, text: snapshot.text))
    }

    /// The history was cut before the item at `index`: notes at or after it are gone.
    func rewound(toBeforeItem index: Int) {
        announced.removeAll { $0.itemIndex >= index }
    }

    /// A summary replaced the start of the history, notes included. When any note was in play, the
    /// summary may have dropped what the file now says, so a note with the whole file replaces them.
    /// `itemCount` is the index that note will have. `nil` when the model only ever saw the prompt's version.
    func summarized(itemCount: Int) -> String? {
        guard !announced.isEmpty else { return nil }
        let text = baseline
        announced = [Announced(itemIndex: itemCount, text: text)]
        return Self.note(for: InstructionSnapshot(name: name, text: text), before: nil)
    }

    static func note(for snapshot: InstructionSnapshot, before: String?) -> String {
        let name = snapshot.name
        guard let text = snapshot.text else {
            return "\(name) was deleted. The project instructions in the system prompt no longer apply."
        }
        if let before {
            let diff = UnifiedDiff.make(path: name, old: before, new: text)
            if diff.utf8.count <= maximumDiffBytes {
                return "\(name) changed on disk. Follow the new version where it differs from the project instructions in the system prompt; this diff shows the change. \(framing)\n\n```diff\n\(diff)```"
            }
        }
        return "\(name) now reads as follows. It replaces any earlier version of the project instructions. \(framing)\n\n\(text)"
    }
}
