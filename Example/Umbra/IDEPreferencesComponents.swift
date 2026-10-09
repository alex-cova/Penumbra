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
        IDESettingsRow(title) {
            HStack(spacing: IDEAppearance.Spacing.xs) {
                Text("\(value)\(valueSuffix)")
                    .font(IDEAppearance.Typography.monoCaption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
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
        IDESettingsRow(title) {
            HStack(spacing: IDEAppearance.Spacing.xs) {
                Text(value, format: .number.precision(.fractionLength(fractionLength)))
                    .font(IDEAppearance.Typography.monoCaption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
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

    @AppStorage("preferencesTypePreviewCollapsed") private var isCollapsed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                    isCollapsed.toggle()
                }
            } label: {
                HStack(spacing: IDEAppearance.Spacing.xs) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 10)
                    Text("Preview")
                        .font(IDEAppearance.Typography.sectionHeader)
                        .textCase(.uppercase)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Preview")
            .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
            .accessibilityHint("Shows or hides the code preview")

            if !isCollapsed {
                previewSourceView
                    .font(Font(IDEEditorFonts.nsFont(familyName: fontName, size: CGFloat(fontSize))))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(IDEAppearance.Spacing.md)
                    .background(Color(hex: palette.background))
                    .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
                    .accessibilityLabel(accessibilityPreview)
            }
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
        func token(_ string: String, _ hex: UInt32) -> Text {
            Text(string).foregroundStyle(Color(hex: hex))
        }
        let signature = Text("\(token("func ", palette.keyword))\(token("greet", palette.function))\(token("(name: ", palette.text))\(token("String", palette.type))\(token(") {\n", palette.text))")
        let body = Text("\(token("\(indent)print", palette.function))\(token("(name)\n}", palette.text))")
        return Text("\(signature)\(body)")
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

    // Split into groups: one 22-modifier chain exceeds the type checker's time limit.
    func body(content: Content) -> some View {
        codeInsightChanges(modeChanges(displayChanges(editingChanges(appearanceChanges(content)))))
    }

    private func appearanceChanges(_ view: some View) -> some View {
        view
            .onChange(of: preferences.fontName) { applyLivePreferences() }
            .onChange(of: preferences.fontLigatures) { applyLivePreferences() }
            .onChange(of: preferences.fontSize) { applyLivePreferences() }
            .onChange(of: preferences.themeID) { applyLivePreferences() }
            .onChange(of: preferences.caretShape) { applyLivePreferences() }
            .onChange(of: preferences.caretColorHex) { applyLivePreferences() }
            .onChange(of: preferences.caretBlinks) { applyLivePreferences() }
            .onChange(of: preferences.caretBlinkIntervalMilliseconds) { applyLivePreferences() }
            .onChange(of: preferences.smoothCaretBlinking) { applyLivePreferences() }
            .onChange(of: preferences.smoothCaretMovement) { applyLivePreferences() }
            .onChange(of: preferences.scaleMarkdownHeadings) { applyLivePreferences() }
            .onChange(of: preferences.keymapPreset) { applyLivePreferences() }
    }

    private func editingChanges(_ view: some View) -> some View {
        view
            .onChange(of: preferences.tabWidth) { applyLivePreferences() }
            .onChange(of: preferences.useSpacesForTab) { applyLivePreferences() }
            .onChange(of: preferences.showLineNumbers) { applyLivePreferences() }
            .onChange(of: preferences.isLineFoldingEnabled) { applyLivePreferences() }
    }

    private func displayChanges(_ view: some View) -> some View {
        view
            .onChange(of: preferences.wrapLines) { applyLivePreferences() }
            .onChange(of: preferences.showMinimap) { applyLivePreferences() }
            .onChange(of: preferences.showScrollbars) { applyLivePreferences() }
            .onChange(of: preferences.isMetalRenderingEnabled) { applyLivePreferences() }
            .onChange(of: preferences.showMethodSeparators) { applyLivePreferences() }
            .onChange(of: preferences.highlightsOccurrencesOfSelection) { applyLivePreferences() }
            .onChange(of: preferences.showInvisibleCharacters) { applyLivePreferences() }
    }

    private func modeChanges(_ view: some View) -> some View {
        view
            .onChange(of: preferences.showPageGuide) { applyLivePreferences() }
            .onChange(of: preferences.pageGuideColumn) { applyLivePreferences() }
            .onChange(of: preferences.lineHeightMultiplier) { applyLivePreferences() }
            .onChange(of: preferences.isTypewriterScrollingEnabled) { applyLivePreferences() }
            .onChange(of: preferences.isDistractionFreeModeEnabled) { applyLivePreferences() }
            .onChange(of: preferences.isFocusModeEnabled) { applyLivePreferences() }
    }

    private func codeInsightChanges(_ view: some View) -> some View {
        view
            .onChange(of: preferences.showsErrorStripe) { applyLivePreferences() }
            .onChange(of: preferences.errorStripeMarkMinHeight) { applyLivePreferences() }
            .onChange(of: preferences.highlightsCurrentScope) { applyLivePreferences() }
            .onChange(of: preferences.showStickyLines) { applyLivePreferences() }
            .onChange(of: preferences.inlayHintsUseEditorFont) { applyLivePreferences() }
            .onChange(of: preferences.javaCodeVisionUsages) { applyLivePreferences() }
            .onChange(of: preferences.javaCodeVisionImplementations) { applyLivePreferences() }
            .onChange(of: preferences.maximumStickyLines) { applyLivePreferences() }
            .onChange(of: preferences.stickyLinesDisabledLanguages) { applyLivePreferences() }
            .onChange(of: preferences.showsDocumentationOnHover) { applyLivePreferences() }
            .onChange(of: preferences.tooltipDelayMilliseconds) { applyLivePreferences() }
            .onChange(of: preferences.autoreparseDelayMilliseconds) { applyLivePreferences() }
            .onChange(of: preferences.inPlaceRefactoring) { applyLivePreferences() }
            .onChange(of: preferences.confirmsInlineVariable) { applyLivePreferences() }
            .onChange(of: preferences.javaSuppressWithComment) { applyLivePreferences() }
    }

    private func applyLivePreferences() {
        workspace.applyPreferencesToAllHosts()
    }
}

// MARK: - Settings layout

/// One titled group of settings: a heading above a rounded card that holds the rows, with an
/// optional explanation underneath.
struct IDESettingsSection<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder var content: Content

    init(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            Text(title)
                .font(IDEAppearance.Typography.titlebarTitle)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: IDEAppearance.Spacing.md) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(IDEAppearance.Spacing.lg)
            .background(
                IDEAppearance.ColorToken.panel,
                in: RoundedRectangle(cornerRadius: IDEAppearance.Radius.panel, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: IDEAppearance.Radius.panel, style: .continuous)
                    .strokeBorder(IDEAppearance.ColorToken.border, lineWidth: 1)
                    .allowsHitTesting(false)
            }

            if let footer {
                Text(footer)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, IDEAppearance.Spacing.xs)
            }
        }
    }
}

/// A label on the left and its control on the right of a fixed column, so every row of a card
/// lines up.
struct IDESettingsRow<Control: View>: View {
    static var labelWidth: Double { 150 }

    let title: String
    @ViewBuilder var control: Control

    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.md) {
            Text(title)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .frame(width: Self.labelWidth, alignment: .leading)
            control
            Spacer(minLength: 0)
        }
    }
}

/// A checkbox with an optional line of explanation under it.
struct IDESettingsToggle: View {
    let title: String
    @Binding var isOn: Bool
    var detail: String?

    init(_ title: String, isOn: Binding<Bool>, detail: String? = nil) {
        self.title = title
        self._isOn = isOn
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.checkbox)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
            if let detail {
                Text(detail)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }
        }
    }
}

/// A color well in the settings control column.
struct IDESettingsColorWell: View {
    let title: String
    @Binding var hex: UInt32
    var isEnabled = true

    var body: some View {
        IDESettingsRow(title) {
            ColorPicker(
                title,
                selection: Binding(
                    get: { Color(hex: hex) },
                    set: { hex = $0.sRGBHex ?? hex }
                ),
                supportsOpacity: false
            )
            .labelsHidden()
            .disabled(!isEnabled)
            .accessibilityLabel(title)
        }
    }
}

/// A pop-up picker in the settings control column.
struct IDESettingsPicker<Selection: Hashable, Content: View>: View {
    let title: String
    @Binding var selection: Selection
    @ViewBuilder var content: Content

    init(_ title: String, selection: Binding<Selection>, @ViewBuilder content: () -> Content) {
        self.title = title
        self._selection = selection
        self.content = content()
    }

    var body: some View {
        IDESettingsRow(title) {
            Picker(title, selection: $selection) { content }
                .labelsHidden()
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .frame(width: 260, alignment: .leading)
        }
    }
}

/// The page every domain pane sits in: a large title, then its sections.
struct IDESettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xl) {
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                    .accessibilityAddTraits(.isHeader)
                content
            }
            .font(IDEAppearance.Typography.body)
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, IDEAppearance.Spacing.xl)
            .padding(.vertical, IDEAppearance.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollIndicators(.automatic)
        .ideSettingsScrollSurface()
    }
}
