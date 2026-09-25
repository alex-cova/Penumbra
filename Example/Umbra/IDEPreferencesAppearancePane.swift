import Penumbra
import SwiftUI

struct IDEPreferencesAppearancePane: View {
    @Bindable var preferences: IDEPreferences

    var body: some View {
        Form {
            Section {
                Picker("Color Theme", selection: $preferences.themeID) {
                    ForEach(ThemeCatalog.palettes(preferring: true)) { palette in
                        Text(palette.name).tag(palette.id)
                    }
                }

                Toggle("Scale Markdown Headings", isOn: $preferences.scaleMarkdownHeadings)
            } header: {
                Text("Theme")
            } footer: {
                Text("Renders markdown headings at progressively larger sizes in the editor.")
            }

            Section {
                Toggle("Line Numbers", isOn: $preferences.showLineNumbers)
                Toggle("Code Folding", isOn: $preferences.isLineFoldingEnabled)
                Toggle("Word Wrap", isOn: $preferences.wrapLines)
                Toggle("Minimap", isOn: $preferences.showMinimap)
                Toggle("Scrollbars", isOn: $preferences.showScrollbars)
            } header: {
                Text("Layout")
            } footer: {
                Text("The vertical scrollbar appears when the minimap is off.")
            }

            Section {
                Toggle("Right Margin", isOn: $preferences.showPageGuide)

                IDEPreferencesIntStepper(
                    title: "Margin Column",
                    value: $preferences.pageGuideColumn,
                    range: 40...200,
                    valueWidth: 28
                )
                .disabled(!preferences.showPageGuide)

                Toggle("Method Separators", isOn: $preferences.showMethodSeparators)
                Toggle("Highlight Occurrences", isOn: $preferences.highlightsOccurrencesOfSelection)
                Toggle("Invisible Characters", isOn: $preferences.showInvisibleCharacters)
            } header: {
                Text("Guides")
            } footer: {
                Text("Method separators draw a hairline between declarations. Invisible characters show tabs and spaces.")
            }

            Section {
                Toggle("Metal Renderer", isOn: $preferences.isMetalRenderingEnabled)
            } header: {
                Text("Rendering")
            } footer: {
                Text("Paints large files on the GPU.")
            }
        }
        .formStyle(.grouped)
    }
}
