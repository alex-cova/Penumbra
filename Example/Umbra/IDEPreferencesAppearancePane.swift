import Penumbra
import SwiftUI

struct IDEPreferencesAppearancePane: View {
    @Bindable var preferences: IDEPreferences

    var body: some View {
        IDESettingsSection("Theme") {
            IDESettingsPicker("Color Theme", selection: $preferences.themeID) {
                ForEach(ThemeCatalog.palettes(preferring: true)) { palette in
                    Text(palette.name).tag(palette.id)
                }
            }

            IDESettingsToggle(
                "Scale Markdown Headings",
                isOn: $preferences.scaleMarkdownHeadings,
                detail: "Renders markdown headings at progressively larger sizes in the editor."
            )
        }

        IDESettingsSection(
            "Layout",
            footer: "The vertical scrollbar appears when the minimap is off."
        ) {
            IDESettingsToggle("Line Numbers", isOn: $preferences.showLineNumbers)
            IDESettingsToggle("Code Folding", isOn: $preferences.isLineFoldingEnabled)
            IDESettingsToggle("Word Wrap", isOn: $preferences.wrapLines)
            IDESettingsToggle("Minimap", isOn: $preferences.showMinimap)
            IDESettingsToggle("Scrollbars", isOn: $preferences.showScrollbars)
        }

        IDESettingsSection(
            "Guides",
            footer: "Method separators draw a hairline between declarations. Invisible characters show tabs and spaces."
        ) {
            IDESettingsToggle("Right Margin", isOn: $preferences.showPageGuide)

            IDEPreferencesIntStepper(
                title: "Margin Column",
                value: $preferences.pageGuideColumn,
                range: 40...200,
                valueWidth: 28
            )
            .disabled(!preferences.showPageGuide)

            IDESettingsToggle("Method Separators", isOn: $preferences.showMethodSeparators)
            IDESettingsToggle("Highlight Occurrences", isOn: $preferences.highlightsOccurrencesOfSelection)
            IDESettingsToggle("Invisible Characters", isOn: $preferences.showInvisibleCharacters)
        }

        IDESettingsSection("Rendering") {
            IDESettingsToggle(
                "Metal Renderer",
                isOn: $preferences.isMetalRenderingEnabled,
                detail: "Paints large files on the GPU."
            )
        }
    }
}
