import Penumbra
import SwiftUI

struct IDEPreferencesEditorPane: View {
    @Bindable var preferences: IDEPreferences

    var body: some View {
        Form {
            Section {
                Picker("Font", selection: $preferences.fontName) {
                    ForEach(IDEEditorFonts.choices(including: preferences.fontName), id: \.self) { familyName in
                        Text(familyName).tag(familyName)
                    }
                }

                IDEPreferencesDoubleStepper(
                    title: "Font Size",
                    value: $preferences.fontSize,
                    range: 9...32,
                    step: 1,
                    fractionLength: 0,
                    valueWidth: 24
                )

                IDEPreferencesDoubleStepper(
                    title: "Line Height",
                    value: $preferences.lineHeightMultiplier,
                    range: 0.8...2.0,
                    step: 0.1,
                    fractionLength: 1
                )
            } header: {
                Text("Typography")
            }

            Section {
                IDEPreferencesIntStepper(
                    title: "Tab Width",
                    value: $preferences.tabWidth,
                    range: 2...8,
                    valueWidth: 16
                )

                Toggle("Indent with Spaces", isOn: $preferences.useSpacesForTab)
            } header: {
                Text("Indentation")
            }

            Section {
                Picker("Keymap", selection: $preferences.keymapPreset) {
                    ForEach(KeymapPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
            } header: {
                Text("Keyboard")
            } footer: {
                Text("Umbra defaults to Sublime Text shortcuts. Switch to IntelliJ if that is what your muscle memory expects.")
            }
        }
        .formStyle(.grouped)
    }
}
