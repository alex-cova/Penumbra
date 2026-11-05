import Foundation
import Penumbra

extension TextView {
    /// The buffer's text, built off the main actor, with the content generation it describes; `nil`
    /// when the caller was cancelled first.
    ///
    /// `text` copies a whole piece-tree document on the main actor (`Sources/Penumbra/CLAUDE.md`,
    /// "Reading a piece-tree buffer"). Work that runs once typing pauses reads through this and
    /// compares `contentGeneration` afterwards instead of comparing strings. The text is shared with
    /// every other caller of ``TextView/materializedText(priority:)`` for the same generation.
    @MainActor
    func snapshotText(priority: TaskPriority = .utility) async -> (text: String, generation: UInt64)? {
        await materializedText(priority: priority)
    }
}
