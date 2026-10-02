import SwiftUI

struct IDEPreferencesProjectPane: View {
    @Bindable var preferences: IDEPreferences

    var body: some View {
        IDESettingsSection(
            "Windows",
            footer: "Applies when a window already has a project. An empty window always takes the folder, and folders opened from the Dock or Finder open in a new window."
        ) {
            IDESettingsPicker("Open Folders", selection: $preferences.openFoldersIn) {
                ForEach(IDEOpenFoldersIn.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
        }
        IDESettingsSection("Explorer") {
            IDESettingsToggle(
                "Flatten Packages",
                isOn: $preferences.flattenJavaPackages,
                detail: "Shows Java packages under each source root as single dotted rows."
            )
            IDESettingsToggle(
                "Hide Empty Middle Packages",
                isOn: $preferences.explorerCompactMiddlePackages,
                detail: "Joins folders that hold only one folder, such as com/example/app, into one row inside a source root."
            )
            IDESettingsToggle(
                "Show Excluded Files",
                isOn: $preferences.explorerShowExcludedFiles,
                detail: "Lists build outputs (build, out, target, .gradle) dimmed. Off hides them."
            )
            IDESettingsPicker("Sort", selection: $preferences.explorerSortOrder) {
                ForEach(IDEExplorerSortOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
            IDESettingsToggle(
                "Folders Always on Top",
                isOn: $preferences.explorerFoldersOnTop,
                detail: "Off mixes folders and files in one sorted list."
            )
            IDESettingsToggle(
                "Always Select Opened File",
                isOn: $preferences.explorerAutoReveal,
                detail: "Selects and scrolls to the active tab's file whenever the tab changes."
            )
        }
    }
}
