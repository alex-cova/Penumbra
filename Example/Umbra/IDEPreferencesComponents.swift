import Penumbra
import SwiftUI

struct IDEPreferencesIntStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step: Int = 1
    var valueWidth: Double = 24
    var valueSuffix = ""

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: IDEAppearance.Spacing.xs) {
                Text("\(value)\(valueSuffix)")
                    .font(IDEAppearance.Typography.monoCaption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: valueWidth, alignment: .trailing)
                    .accessibilityHidden(true)
                Stepper(title, value: $value, in: range, step: step)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel(title)
                    .accessibilityValue(Text("\(value)\(valueSuffix)"))
            }
        }
    }
}

struct IDEPreferencesDoubleStepper: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var fractionLength: Int = 0
    var valueWidth: Double = 28

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: IDEAppearance.Spacing.xs) {
                Text(value, format: .number.precision(.fractionLength(fractionLength)))
                    .font(IDEAppearance.Typography.monoCaption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: valueWidth, alignment: .trailing)
                    .accessibilityHidden(true)
                Stepper(title, value: $value, in: range, step: step)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel(title)
                    .accessibilityValue(
                        Text(value, format: .number.precision(.fractionLength(fractionLength)))
                    )
            }
        }
    }
}

struct IDEPreferencesTypePreview: View {
    let themeID: String
    let fontName: String
    let fontSize: Double
    let tabWidth: Int
    let useSpacesForTab: Bool

    private var palette: ThemePalette {
        ThemeCatalog.palette(id: themeID, fallbackDark: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            Text("Preview")
                .font(IDEAppearance.Typography.sectionHeader)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .accessibilityHidden(true)

            previewSourceView
                .font(Font(IDEEditorFonts.nsFont(familyName: fontName, size: CGFloat(fontSize))))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(IDEAppearance.Spacing.md)
                .background(Color(hex: palette.background))
                .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
                .accessibilityLabel(accessibilityPreview)
        }
        .padding(.horizontal, IDEAppearance.Spacing.lg)
        .padding(.vertical, IDEAppearance.Spacing.md)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(IDEAppearance.ColorToken.border)
                .frame(height: 1)
        }
        .background(IDEAppearance.ColorToken.sidebar)
    }

    private var previewSourceView: Text {
        let indent = useSpacesForTab
            ? String(repeating: " ", count: tabWidth)
            : "\t"
        return Text("func ")
            .foregroundStyle(Color(hex: palette.keyword))
        + Text("greet")
            .foregroundStyle(Color(hex: palette.function))
        + Text("(name: ")
            .foregroundStyle(Color(hex: palette.text))
        + Text("String")
            .foregroundStyle(Color(hex: palette.type))
        + Text(") {\n")
            .foregroundStyle(Color(hex: palette.text))
        + Text("\(indent)print")
            .foregroundStyle(Color(hex: palette.function))
        + Text("(name)\n}")
            .foregroundStyle(Color(hex: palette.text))
    }

    private var accessibilityPreview: String {
        let indent = useSpacesForTab ? "spaces" : "tabs"
        let size = fontSize.formatted(.number.precision(.fractionLength(0)))
        let themeName = palette.name
        return "Preview using \(themeName) in \(fontName) at \(size) points, indenting with \(indent), tab width \(tabWidth)"
    }
}

struct IDEPreferencesLiveUpdateModifier: ViewModifier {
    @Bindable var preferences: IDEPreferences
    let workspace: IDEWorkspace

    func body(content: Content) -> some View {
        content
            .onChange(of: preferences.fontName) { applyLivePreferences() }
            .onChange(of: preferences.fontSize) { applyLivePreferences() }
            .onChange(of: preferences.themeID) { applyLivePreferences() }
            .onChange(of: preferences.scaleMarkdownHeadings) { applyLivePreferences() }
            .onChange(of: preferences.keymapPreset) { applyLivePreferences() }
            .onChange(of: preferences.tabWidth) { applyLivePreferences() }
            .onChange(of: preferences.useSpacesForTab) { applyLivePreferences() }
            .onChange(of: preferences.showLineNumbers) { applyLivePreferences() }
            .onChange(of: preferences.isLineFoldingEnabled) { applyLivePreferences() }
            .onChange(of: preferences.wrapLines) { applyLivePreferences() }
            .onChange(of: preferences.showMinimap) { applyLivePreferences() }
            .onChange(of: preferences.showScrollbars) { applyLivePreferences() }
            .onChange(of: preferences.isMetalRenderingEnabled) { applyLivePreferences() }
            .onChange(of: preferences.showMethodSeparators) { applyLivePreferences() }
            .onChange(of: preferences.highlightsOccurrencesOfSelection) { applyLivePreferences() }
            .onChange(of: preferences.showInvisibleCharacters) { applyLivePreferences() }
            .onChange(of: preferences.showPageGuide) { applyLivePreferences() }
            .onChange(of: preferences.pageGuideColumn) { applyLivePreferences() }
            .onChange(of: preferences.lineHeightMultiplier) { applyLivePreferences() }
            .onChange(of: preferences.isTypewriterScrollingEnabled) { applyLivePreferences() }
            .onChange(of: preferences.isDistractionFreeModeEnabled) { applyLivePreferences() }
            .onChange(of: preferences.isFocusModeEnabled) { applyLivePreferences() }
    }

    private func applyLivePreferences() {
        workspace.applyPreferencesToAllHosts()
    }
}
