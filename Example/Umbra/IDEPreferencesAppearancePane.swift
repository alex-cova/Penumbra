import Penumbra
import SwiftUI

struct IDEPreferencesAppearancePane: View {
    @Bindable var preferences: IDEPreferences

    var body: some View {
        IDESettingsSection("Interface") {
            IDESettingsPicker("UI Font", selection: $preferences.uiFontName) {
                ForEach(IDEUIFonts.choices(including: preferences.uiFontName), id: \.self) { familyName in
                    Text(familyName).tag(familyName)
                }
            }

            IDEPreferencesDoubleStepper(
                title: "UI Font Size",
                value: $preferences.uiFontSize,
                range: 10...24,
                step: 1,
                fractionLength: 0,
                valueWidth: 24
            )
        }

        IDESettingsSection("Welcome Page") {
            IDESettingsPicker("Background", selection: $preferences.welcomeBackground) {
                ForEach(IDEWelcomeBackground.allCases) { background in
                    Text(background.title).tag(background)
                }
            }
        }
    }
}
