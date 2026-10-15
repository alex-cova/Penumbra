import SwiftUI

/// Settings ▸ Saving: when files are written and how unsaved ones are shown.
struct IDEPreferencesSavingPane: View {
    @Bindable var preferences: IDEPreferences

    var body: some View {
        IDESettingsSection(
            "Autosave",
            footer: "Unsaved files are written without asking. A file that changed on disk is never overwritten this way; its tab shows the banner instead. Local History keeps what was there."
        ) {
            IDESettingsToggle(
                "Save files when switching to another application or the built-in terminal",
                isOn: $preferences.saveOnFocusLoss
            )
            IDESettingsToggle("Save files if the editor is idle", isOn: $preferences.saveWhenIdle)
            IDEPreferencesIntStepper(
                title: "Idle for",
                value: $preferences.idleSaveSeconds,
                range: IDEPreferences.idleSaveSecondsRange,
                valueWidth: 64,
                valueSuffix: " s"
            )
            .disabled(!preferences.saveWhenIdle)
        }

        IDESettingsSection(
            "Actions on Save",
            footer: "They run on every save: autosave, ⌘S, Save All, and before a run or a git operation. Each one is skipped for a file it does not apply to, and a tab closing in the background does not run them."
        ) {
            IDESettingsToggle(
                "Reformat code",
                isOn: $preferences.reformatOnSave,
                detail: "With the language's formatter: Java, JSON, and any language whose server formats."
            )
            IDESettingsToggle(
                "Whole file, not only lines changed since the last commit",
                isOn: $preferences.reformatsWholeFileOnSave
            )
            .disabled(!preferences.reformatOnSave)
            IDESettingsToggle(
                "Optimize imports",
                isOn: $preferences.javaOptimizeImportsOnSave,
                detail: "Removes unused imports and sorts the rest, for languages that offer it."
            )
            IDESettingsToggle(
                "Run code cleanup",
                isOn: $preferences.codeCleanupOnSave,
                detail: "Applies the quick fixes of the active inspection profile to a Java file."
            )
            IDESettingsPicker("Strip trailing spaces", selection: $preferences.stripTrailingWhitespaceOnSave) {
                ForEach(IDEStripWhitespaceScope.allCases) { scope in
                    Text(scope.displayName).tag(scope)
                }
            }
            IDESettingsToggle(
                "Keep trailing spaces on the caret line",
                isOn: $preferences.keepsTrailingWhitespaceOnCaretLine
            )
            .disabled(preferences.stripTrailingWhitespaceOnSave == .off)
            IDESettingsToggle("Ensure a line break at the end of the file", isOn: $preferences.ensureNewlineAtEndOfFile)
            IDESettingsToggle(
                "Build project",
                isOn: $preferences.buildProjectOnSave,
                detail: "Runs Build Project a second after you save with ⌘S or Save All, once the project has synced."
            )
        }

        IDESettingsSection(
            "Editor Tabs",
            footer: "A dot marks a tab, the file in the Explorer and the window's close button while the file has unsaved changes."
        ) {
            IDESettingsToggle("Mark Modified", isOn: $preferences.markModifiedTabs)
        }
    }
}
