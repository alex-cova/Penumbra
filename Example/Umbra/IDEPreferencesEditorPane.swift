import Penumbra
import SwiftUI

struct IDEPreferencesEditorPane: View {
    @Bindable var preferences: IDEPreferences

    var body: some View {
        IDESettingsSection("Theme") {
            IDESettingsPicker("Color Theme", selection: $preferences.themeID) {
                ForEach(ThemeCatalog.palettes(preferring: true)) { palette in
                    Text(palette.name).tag(palette.id)
                }
            }
        }

        IDESettingsSection("Typography") {
            IDESettingsPicker("Font", selection: $preferences.fontName) {
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

            IDESettingsToggle(
                "Scale Markdown Headings",
                isOn: $preferences.scaleMarkdownHeadings,
                detail: "Renders markdown headings at progressively larger sizes in the editor."
            )
        }

        IDESettingsSection("Indentation") {
            IDEPreferencesIntStepper(
                title: "Tab Width",
                value: $preferences.tabWidth,
                range: 2...8,
                valueWidth: 16
            )

            IDESettingsToggle("Indent with Spaces", isOn: $preferences.useSpacesForTab)
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

        IDESettingsSection(
            "Keyboard",
            footer: "Umbra defaults to Sublime Text shortcuts. Switch to IntelliJ if that is what your muscle memory expects."
        ) {
            IDESettingsPicker("Keymap", selection: $preferences.keymapPreset) {
                ForEach(KeymapPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
        }
    }
}
