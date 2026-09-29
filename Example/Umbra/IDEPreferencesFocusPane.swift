import SwiftUI

struct IDEPreferencesFocusPane: View {
    @Bindable var preferences: IDEPreferences

    var body: some View {
        IDESettingsSection("Writing Modes") {
            IDESettingsToggle(
                "Typewriter Scrolling",
                isOn: $preferences.isTypewriterScrollingEnabled,
                detail: "Keeps the active line vertically centered."
            )
            IDESettingsToggle(
                "Distraction Free",
                isOn: $preferences.isDistractionFreeModeEnabled,
                detail: "Fades chrome after a short idle period."
            )
            IDESettingsToggle(
                "Focus Mode",
                isOn: $preferences.isFocusModeEnabled,
                detail: "Dims text outside the current sentence or paragraph."
            )
        }
    }
}
