import EditorIntelligence
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

        IDESettingsSection(
            "Caret",
            footer: "A block covers the next character and redraws it in the editor background. An underline sits on the baseline."
        ) {
            IDESettingsPicker("Shape", selection: $preferences.caretShape) {
                Text("Bar").tag(CaretShape.bar)
                Text("Block").tag(CaretShape.block)
                Text("Underline").tag(CaretShape.underline)
            }

            IDESettingsToggle(
                "Match Theme Color",
                isOn: Binding(
                    get: { preferences.caretColorHex == nil },
                    set: { matchesTheme in
                        if matchesTheme {
                            preferences.caretColorHex = nil
                        } else if preferences.caretColorHex == nil {
                            preferences.caretColorHex = ThemeCatalog.palette(
                                id: preferences.themeID,
                                fallbackDark: true
                            ).text
                        }
                    }
                ),
                detail: "Uses the theme's text color. Turn this off to pick a color."
            )

            if let customCaretColor = preferences.caretColorHex {
                IDESettingsColorWell(
                    title: "Color",
                    hex: Binding(
                        get: { preferences.caretColorHex ?? customCaretColor },
                        set: { preferences.caretColorHex = $0 }
                    )
                )
            }

            IDESettingsToggle("Blink Caret", isOn: $preferences.caretBlinks)

            IDEPreferencesIntStepper(
                title: "Blink Interval",
                value: $preferences.caretBlinkIntervalMilliseconds,
                range: 100...2000,
                step: 50,
                valueWidth: 56,
                valueSuffix: " ms"
            )
            .disabled(!preferences.caretBlinks)

            IDESettingsToggle(
                "Smooth Blinking",
                isOn: $preferences.smoothCaretBlinking,
                detail: "Fades the caret in and out instead of switching it. Ignored when the system asks to reduce motion."
            )
            .disabled(!preferences.caretBlinks)

            IDESettingsToggle(
                "Smooth Movement",
                isOn: $preferences.smoothCaretMovement,
                detail: "Glides the caret to its new position instead of jumping. Ignored when the system asks to reduce motion."
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

        IDESettingsSection(
            "Sticky Lines",
            footer: "While you scroll, the headers of the classes, methods and blocks around the top line stay pinned. Click one to jump to it; right-click for these settings."
        ) {
            IDESettingsToggle("Show Sticky Lines", isOn: $preferences.showStickyLines)

            IDEPreferencesIntStepper(
                title: "Maximum Lines",
                value: $preferences.maximumStickyLines,
                range: 1...10,
                valueWidth: 24
            )
            .disabled(!preferences.showStickyLines)

            if !preferences.stickyLinesDisabledLanguages.isEmpty {
                IDESettingsRow("Disabled For") {
                    HStack(spacing: IDEAppearance.Spacing.sm) {
                        Text(preferences.stickyLinesDisabledLanguages.sorted().joined(separator: ", "))
                            .font(IDEAppearance.Typography.monoCaption)
                            .foregroundStyle(IDEAppearance.ColorToken.muted)
                        Button("Enable All") { preferences.stickyLinesDisabledLanguages = [] }
                            .controlSize(.small)
                    }
                }
            }
        }

        IDESettingsSection(
            "Code Insight",
            footer: "The error stripe ticks every problem along the trailing edge. The scope bar marks the block the caret is in, beside the fold arrows (code folding must be on). Tooltips show a problem's message, and optionally documentation, when the pointer rests on code. The tooltip delay also paces fold previews and the gutter's tooltips; those may need a relaunch to follow a change."
        ) {
            IDESettingsToggle("Error Stripe", isOn: $preferences.showsErrorStripe)

            IDEPreferencesIntStepper(
                title: "Stripe Mark Height",
                value: $preferences.errorStripeMarkMinHeight,
                range: 1...8,
                valueWidth: 28,
                valueSuffix: " pt"
            )
            .disabled(!preferences.showsErrorStripe)

            IDESettingsToggle("Highlight Current Scope", isOn: $preferences.highlightsCurrentScope)
            IDESettingsToggle("Documentation on Hover", isOn: $preferences.showsDocumentationOnHover)

            IDEPreferencesIntStepper(
                title: "Tooltip Delay",
                value: $preferences.tooltipDelayMilliseconds,
                range: 0...2000,
                step: 50,
                valueWidth: 56,
                valueSuffix: " ms"
            )

            IDEPreferencesIntStepper(
                title: "Autoreparse Delay",
                value: $preferences.autoreparseDelayMilliseconds,
                range: 0...3000,
                step: 50,
                valueWidth: 56,
                valueSuffix: " ms"
            )

            IDESettingsPicker("Next Problem (F2)", selection: $preferences.nextErrorScope) {
                Text("All problems").tag(ProblemNavigationScope.all)
                Text("Highest severity only").tag(ProblemNavigationScope.highestSeverity)
            }
        }

        IDESettingsSection(
            "Refactoring",
            footer: "In-place mode marks the code a rename or extract will change and applies it without a preview when nothing is ambiguous. Turn it off to always review the changes first."
        ) {
            IDESettingsToggle("In-Place Mode", isOn: $preferences.inPlaceRefactoring)
            IDESettingsToggle("Preselect Name on Rename", isOn: $preferences.preselectsRenamedName)
            IDESettingsToggle("Confirm Inline Variable", isOn: $preferences.confirmsInlineVariable)
            IDESettingsToggle(
                "Suppress with Comment",
                isOn: $preferences.javaSuppressWithComment,
                detail: "Suppress quick fixes add //noinspection above the statement instead of @SuppressWarnings."
            )
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
