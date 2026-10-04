import AgentKit
import Foundation
import Observation

/// One row of the list above the composer: a command, a file, a skill, an earlier prompt.
struct IDEAgentSuggestion: Identifiable, Equatable {
    let id: String
    var icon: String
    var title: String
    var detail: String?
    /// Replaces the trigger's range in the text when the row is accepted.
    var insertion: String
    /// What accepting does instead of inserting: the composer is emptied and this is carried out.
    var payload: IDEAgentSuggestionPayload?
}

/// An action a suggestion row stands for.
enum IDEAgentSuggestionPayload: Equatable {
    /// Show this saved conversation.
    case resume(UUID)
    /// Switch to this mode.
    case mode(PermissionMode)
    /// Run this command now, with no arguments.
    case run(String)
}

/// What the suggestion list shows and which row is highlighted. Owned by the panel; the composer
/// field feeds it as the text and caret change.
@MainActor
@Observable
final class IDEAgentComposerState {
    private(set) var trigger: IDEAgentComposerTrigger = .none
    private(set) var suggestions: [IDEAgentSuggestion] = []
    var selectedIndex = 0
    /// Ctrl-R is on: the field's text is a search of earlier prompts.
    var isSearchingHistory = false
    /// A trigger the user closed with Esc stays closed until the text around it changes.
    @ObservationIgnored private var dismissed: IDEAgentComposerTrigger?

    var isShowingSuggestions: Bool { !suggestions.isEmpty }

    var selected: IDEAgentSuggestion? {
        suggestions.indices.contains(selectedIndex) ? suggestions[selectedIndex] : nil
    }

    func update(trigger newTrigger: IDEAgentComposerTrigger, suggestions newSuggestions: [IDEAgentSuggestion]) {
        if newTrigger != trigger { selectedIndex = 0 }
        trigger = newTrigger
        let hidden = newTrigger == .none || newTrigger == dismissed
        if newTrigger != dismissed { dismissed = nil }
        suggestions = hidden ? [] : newSuggestions
        selectedIndex = min(selectedIndex, max(suggestions.count - 1, 0))
    }

    func dismiss() {
        dismissed = trigger
        suggestions = []
        isSearchingHistory = false
    }

    func move(by delta: Int) {
        guard !suggestions.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + suggestions.count) % suggestions.count
    }

    func reset() {
        isSearchingHistory = false
        trigger = .none
        suggestions = []
        selectedIndex = 0
        dismissed = nil
    }
}
