import SwiftUI

/// Settings ▸ Project ▸ Version Control: how Update Project integrates, which branches are
/// protected, and the opt-in background fetch.
struct IDEGitSettingsSection: View {
    @State private var rebase = IDEGitPreferences.updateStrategy == .rebase
    @State private var asksBeforeUpdate = IDEGitPreferences.asksBeforeUpdate
    @State private var protectedBranches = UserDefaults.standard.string(forKey: IDEGitPreferences.protectedBranchesKey)
        ?? IDEGitPreferences.defaultProtectedBranches
    @State private var fetchMinutes = IDEGitPreferences.fetchIntervalMinutes

    var body: some View {
        IDESettingsSection(
            "Version Control",
            footer: "Protected branches refuse a force push and a delete from here. Patterns may use * (release/*). Background fetch is off at 0 and only runs while Umbra is the active app; it never asks for a password."
        ) {
            IDESettingsPicker("Update Project", selection: $rebase) {
                Text("Merge").tag(false)
                Text("Rebase").tag(true)
            }
            .onChange(of: rebase) { IDEGitPreferences.updateStrategy = rebase ? .rebase : .merge }
            IDESettingsToggle(
                "Ask Before Updating",
                isOn: $asksBeforeUpdate,
                detail: "Off updates with the choice above and saves uncommitted changes around it."
            )
            .onChange(of: asksBeforeUpdate) { IDEGitPreferences.asksBeforeUpdate = asksBeforeUpdate }
            IDESettingsRow("Protected Branches") {
                TextField("main, master", text: $protectedBranches)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: protectedBranches) {
                        UserDefaults.standard.set(protectedBranches, forKey: IDEGitPreferences.protectedBranchesKey)
                    }
            }
            IDEPreferencesIntStepper(
                title: "Fetch Every", value: $fetchMinutes, range: 0...240, step: 5,
                valueWidth: 56, valueSuffix: " min"
            )
            .onChange(of: fetchMinutes) { IDEGitPreferences.fetchIntervalMinutes = fetchMinutes }
        }
    }
}
