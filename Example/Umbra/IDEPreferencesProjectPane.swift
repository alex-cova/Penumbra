import SwiftUI

struct IDEPreferencesProjectPane: View {
    @Bindable var preferences: IDEPreferences

    var body: some View {
        IDESettingsSection("Explorer") {
            IDESettingsToggle(
                "Flatten Packages",
                isOn: $preferences.flattenJavaPackages,
                detail: "Shows Java packages under each source root as single dotted rows."
            )
        }
    }
}
