import SwiftUI

struct IDEPreferencesView: View {
    @ObservedObject var preferences: IDEPreferences

    var body: some View {
        Form {
            Section("Editor") {
                HStack {
                    Text("Font Size")
                    Spacer()
                    TextField("", value: $preferences.fontSize, format: .number)
                        .frame(width: 48)
                        .multilineTextAlignment(.trailing)
                }
                Stepper(value: $preferences.fontSize, in: 9...32, step: 1) {
                    EmptyView()
                }
                .labelsHidden()

                Picker("Keymap", selection: $preferences.keymapPreset) {
                    ForEach(KeymapPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }

                Stepper("Tab Width: \(preferences.tabWidth)", value: $preferences.tabWidth, in: 2...8)
                Toggle("Indent with Spaces", isOn: $preferences.useSpacesForTab)
            }

            Section("Display") {
                Toggle("Line Numbers", isOn: $preferences.showLineNumbers)
                Toggle("Code Folding", isOn: $preferences.isLineFoldingEnabled)
                Toggle("Word Wrap", isOn: $preferences.wrapLines)
                Toggle("Minimap", isOn: $preferences.showMinimap)
                Toggle("Metal Renderer", isOn: $preferences.isMetalRenderingEnabled)
            }
        }
        .frame(width: 420, height: 360)
        .padding()
    }
}
