import SwiftUI

struct IDEPreferencesProjectPane: View {
    @Bindable var preferences: IDEPreferences

    var body: some View {
        Form {
            Section {
                Toggle("Flatten Packages", isOn: $preferences.flattenJavaPackages)
            } header: {
                Text("Explorer")
            } footer: {
                Text("Shows Java packages under each source root as single dotted rows.")
            }
        }
        .formStyle(.grouped)
    }
}
