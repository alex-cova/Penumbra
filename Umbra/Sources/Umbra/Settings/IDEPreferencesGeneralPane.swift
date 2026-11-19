import Penumbra
import SwiftUI

/// Settings ▸ General. Retention uses the keys Local History already reads.
struct IDEPreferencesGeneralPane: View {
    @Bindable var preferences: IDEPreferences
    @State private var automaticallyChecksForUpdates = IDEAppUpdater.automaticallyChecksForUpdates
    @State private var automaticallyDownloadsUpdates = IDEAppUpdater.automaticallyDownloadsUpdates

    var body: some View {
        IDESettingsSection("Startup") {
            IDESettingsToggle(
                "Open with empty file",
                isOn: $preferences.opensWithEmptyFile,
                detail: "A window with no files open starts with an empty Untitled tab instead of the Welcome screen."
            )
        }

        if IDEAppUpdater.isEnabled {
            IDESettingsSection("Updates") {
                Toggle("Automatically check for updates", isOn: $automaticallyChecksForUpdates)
                    .onChange(of: automaticallyChecksForUpdates) {
                        IDEAppUpdater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
                    }
                Toggle("Automatically download updates", isOn: $automaticallyDownloadsUpdates)
                    .onChange(of: automaticallyDownloadsUpdates) {
                        IDEAppUpdater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
                    }
            }
        }

        IDESettingsSection(
            "Local History",
            footer: "Unnamed revisions older than this, and the oldest ones past the size, are removed. A revision you label is kept."
        ) {
            IDEPreferencesStepper(
                title: "Keep for Days", value: $preferences.localHistoryDays, range: 1...365, valueWidth: 72, valueSuffix: " days")
            IDEPreferencesStepper(
                title: "Keep up to", value: $preferences.localHistoryMegabytes, range: 50...10_000, step: 50, valueWidth: 72, valueSuffix: " MB")
        }
    }
}
