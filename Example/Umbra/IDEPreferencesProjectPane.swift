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
        }
    }
}
