import SwiftUI

struct IDEDockerPreferencesPane: View {
    @AppStorage(IDEDockerCLI.executablePreferenceKey) private var executable = ""

    var body: some View {
        IDESettingsSection("Docker CLI", footer: "Leave the path blank to find Docker automatically.") {
            IDESettingsRow("Executable") {
                TextField("/usr/local/bin/docker", text: $executable)
                    .accessibilityLabel("Docker executable path")
            }
        }
    }
}
