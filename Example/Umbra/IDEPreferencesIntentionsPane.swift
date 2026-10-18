import JavaIntelligence
import SwiftUI

/// Settings › Java › Intentions: every Java intention, one group at a time, with a description,
/// a before-and-after example, and a checkbox. Only the ones turned off are stored.
struct IDEPreferencesIntentionsPane: View {
    @Bindable var preferences: IDEPreferences
    @Environment(IDEWorkspace.self) private var workspace
    @State private var query = ""
    @State private var selectedCategory: JavaIntentionCategory = .controlFlow

    private var matching: [JavaIntention] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return JavaIntention.all }
        return JavaIntention.all.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.summary.localizedCaseInsensitiveContains(query)
                || $0.category.title.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        IDESettingsSection(
            "Intentions",
            footer: "An intention rewrites the code at the caret. It is not a warning. Option-Return, or the bulb on the caret line, lists the ones that apply. A quick fix for an error stays in that list either way."
        ) {
            IDESettingsToggle("Show Intention Bulb", isOn: $preferences.javaShowIntentionBulb)
            IDESettingsToggle(
                "Show Preview",
                isOn: $preferences.javaShowIntentionPreview,
                detail: "The lines an intention would write, beside the list."
            )
            TextField("Filter intentions", text: $query)
                .textFieldStyle(.roundedBorder)
            groupPicker
        }
        .onAppear { focusRequested() }
        .onChange(of: workspace.focusedIntentionID) { _, _ in focusRequested() }
        .onChange(of: query) { _, _ in ensureVisibleSelection() }
    }

    @ViewBuilder
    private var groupPicker: some View {
        let intentions = matching
        let categories = JavaIntentionCategory.allCases.filter { category in intentions.contains { $0.category == category } }
        if categories.isEmpty {
            Text(query.isEmpty ? "No intentions." : "No intention matches \u{201C}\(query)\u{201D}.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        } else {
            Picker("Group", selection: $selectedCategory) {
                ForEach(categories, id: \.self) { category in
                    let group = intentions.filter { $0.category == category }
                    let enabled = group.filter { !preferences.javaDisabledIntentions.contains($0.id) }.count
                    Text("\(category.title) (\(enabled)/\(group.count))").tag(category)
                }
            }
            let selected = intentions.filter { $0.category == selectedCategory }
            // Lazy: rows below the fold are not realized while scrolling. The rows hold
            // no state themselves (it lives in this pane, which stays mounted), so
            // scrolling away and back loses nothing.
            LazyVStack(alignment: .leading, spacing: IDEAppearance.Spacing.md) {
                groupToggle(selectedCategory, intentions: selected)
                ForEach(selected) { intention in
                    IDEIntentionSettingsRow(preferences: preferences, intention: intention)
                }
            }
        }
    }

    private func groupToggle(_ category: JavaIntentionCategory, intentions: [JavaIntention]) -> some View {
        let enabledCount = intentions.filter { !preferences.javaDisabledIntentions.contains($0.id) }.count
        let symbol = enabledCount == intentions.count ? "checkmark.square.fill" : (enabledCount == 0 ? "square" : "minus.square.fill")
        return Button {
            let turnOn = enabledCount != intentions.count
            for intention in intentions {
                if turnOn {
                    preferences.javaDisabledIntentions.remove(intention.id)
                } else {
                    preferences.javaDisabledIntentions.insert(intention.id)
                }
            }
        } label: {
            Label(enabledCount == intentions.count ? "Turn off all in \(category.title)" : "Turn on all in \(category.title)", systemImage: symbol)
                .font(IDEAppearance.Typography.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(IDEAppearance.ColorToken.muted)
    }

    private func focusRequested() {
        guard let id = workspace.focusedIntentionID, let intention = JavaIntention.named(id) else { return }
        workspace.focusedIntentionID = nil
        query = ""
        selectedCategory = intention.category
    }

    private func ensureVisibleSelection() {
        let intentions = matching
        guard !intentions.contains(where: { $0.category == selectedCategory }) else { return }
        if let first = JavaIntentionCategory.allCases.first(where: { category in intentions.contains { $0.category == category } }) {
            selectedCategory = first
        }
    }
}

/// One intention with its description and before/after example. A stable identity per
/// intention id, so toggling one row does not rebuild the others.
private struct IDEIntentionSettingsRow: View {
    @Bindable var preferences: IDEPreferences
    let intention: JavaIntention

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            Toggle(intention.title, isOn: enabled)
                .toggleStyle(.checkbox)
            Text(intention.summary)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            VStack(alignment: .leading, spacing: 2) {
                example("Before", intention.before)
                example("After", intention.after)
            }
        }
        .padding(.bottom, IDEAppearance.Spacing.xs)
    }

    private func example(_ label: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: IDEAppearance.Spacing.sm) {
            Text(label)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(width: 44, alignment: .leading)
            Text(text)
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .textSelection(.enabled)
        }
    }

    private var enabled: Binding<Bool> {
        Binding {
            !preferences.javaDisabledIntentions.contains(intention.id)
        } set: { isOn in
            if isOn {
                preferences.javaDisabledIntentions.remove(intention.id)
            } else {
                preferences.javaDisabledIntentions.insert(intention.id)
            }
        }
    }
}
