import SwiftUI

struct IDEPreferencesFocusPane: View {
    @Bindable var preferences: IDEPreferences

    var body: some View {
        Form {
            Section {
                Toggle("Typewriter Scrolling", isOn: $preferences.isTypewriterScrollingEnabled)
                Toggle("Distraction Free", isOn: $preferences.isDistractionFreeModeEnabled)
                Toggle("Focus Mode", isOn: $preferences.isFocusModeEnabled)
            } header: {
                Text("Writing Modes")
            } footer: {
                Text("Typewriter scrolling keeps the active line vertically centered. Distraction free fades chrome after a short idle period. Focus mode dims text outside the current sentence or paragraph.")
            }
        }
        .formStyle(.grouped)
    }
}
