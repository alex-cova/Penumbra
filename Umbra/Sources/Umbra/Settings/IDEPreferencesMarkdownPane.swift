import AppKit
import Penumbra
import SwiftUI

/// Settings ▸ Markdown: how the Markdown preview reads. Every change reaches open previews live
/// (`IDEPreferencesLiveUpdateModifier`); PDF and diagram exports are always light.
struct IDEPreferencesMarkdownPane: View {
    @Bindable var preferences: IDEPreferences

    /// Installed font families for "Other…", read once.
    private static let fontFamilies: [String] = NSFontManager.shared.availableFontFamilies
        .filter { !$0.hasPrefix(".") }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

    private var appearance: Binding<IDEMarkdownPreviewAppearanceChoice> {
        Binding(
            get: { IDEMarkdownPreviewAppearanceChoice(preferences.markdownPreviewAppearance) },
            set: { preferences.markdownPreviewAppearance = $0.appearance }
        )
    }

    /// The family "Other…" uses; empty until one is picked, which reads as the editor's font.
    private var customFamily: Binding<String> {
        Binding(
            get: { preferences.markdownPreview.customFontFamily },
            set: { preferences.markdownPreview.customFontFamily = $0 }
        )
    }

    var body: some View {
        IDESettingsSection(
            "Appearance",
            footer: "The sun and moon button in the preview switches between light and dark too. Exported PDFs and diagram images are always light."
        ) {
            IDESettingsPicker("Preview appearance", selection: appearance) {
                ForEach(IDEMarkdownPreviewAppearanceChoice.allCases) { choice in
                    Text(choice.displayName).tag(choice)
                }
            }
            IDESettingsToggle(
                "Animate when the preview opens",
                isOn: $preferences.markdownPreview.animatesAppearance,
                detail: "The page fades in and settles from a larger size. With Reduce Motion on, it only fades."
            )
        }

        IDESettingsSection("Typography") {
            IDESettingsPicker("Typeface", selection: $preferences.markdownPreview.typeface) {
                ForEach(IDEMarkdownPreviewSettings.Typeface.allCases) { face in
                    Text(face.displayName).tag(face)
                }
            }
            if preferences.markdownPreview.typeface == .custom {
                IDESettingsPicker("Font family", selection: customFamily) {
                    Text("Choose a Font").tag("")
                    ForEach(Self.fontFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
            }
            IDESettingsToggle("Use the editor's font size", isOn: $preferences.markdownPreview.followsEditorFontSize)
            IDEPreferencesStepper(
                title: "Font size",
                value: $preferences.markdownPreview.fontSize,
                range: IDEMarkdownPreviewSettings.fontSizeRange,
                valueWidth: 44,
                valueSuffix: " pt"
            )
            .disabled(preferences.markdownPreview.followsEditorFontSize)
            IDESettingsPicker("Line spacing", selection: $preferences.markdownPreview.lineSpacing) {
                ForEach(IDEMarkdownPreviewSettings.LineSpacing.allCases) { spacing in
                    Text(spacing.displayName).tag(spacing)
                }
            }
        }

        IDESettingsSection(
            "Text Layout",
            footer: "With a line length limit the text sits in a centered column; a window narrower than the limit uses its full width. Numbering leaves a document's only top-level heading alone, as its title. Paragraphs are indented only when they follow another paragraph, as in books."
        ) {
            IDESettingsToggle("Limit line length", isOn: $preferences.markdownPreview.limitsLineLength)
            IDEPreferencesStepper(
                title: "Characters per line",
                value: $preferences.markdownPreview.lineLength,
                range: IDEMarkdownPreviewSettings.lineLengthRange,
                step: 5,
                valueWidth: 44
            )
            .disabled(!preferences.markdownPreview.limitsLineLength)
            IDESettingsPicker("Heading alignment", selection: $preferences.markdownPreview.headingAlignment) {
                ForEach(IDEMarkdownPreviewSettings.HeadingAlignment.allCases) { alignment in
                    Text(alignment.displayName).tag(alignment)
                }
            }
            IDESettingsToggle(
                "Number headings",
                isOn: $preferences.markdownPreview.numbersHeadings,
                detail: "1, 1.1, 1.1.1 before each heading."
            )
            IDESettingsToggle("Indent paragraphs", isOn: $preferences.markdownPreview.indentsParagraphs)
            IDESettingsToggle("Justify paragraphs", isOn: $preferences.markdownPreview.justifiesParagraphs)
        }

        IDESettingsSection(
            "Preview Layout",
            footer: "Alongside keeps the editor editable, so the rendered page follows the buffer as it is typed."
        ) {
            IDESettingsToggle(
                "Show preview alongside the editor",
                isOn: $preferences.markdownPreview.sideBySide,
                detail: "Markdown and Mermaid files open split with the rendered page, updating live."
            )
        }

        IDESettingsSection("Tables and Diagrams") {
            IDESettingsPicker("Table columns", selection: $preferences.markdownPreview.tableDensity) {
                ForEach(IDEMarkdownPreviewSettings.TableDensity.allCases) { density in
                    Text(density.displayName).tag(density)
                }
            }
            IDESettingsToggle(
                "Open diagrams in a viewer when clicked",
                isOn: $preferences.markdownPreview.opensDiagramsOnClick,
                detail: "A window to zoom a Mermaid diagram and export it as PNG or JPEG."
            )
        }
    }
}
