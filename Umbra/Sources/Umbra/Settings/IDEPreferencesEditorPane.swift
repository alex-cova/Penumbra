import AgentKitMLX
import EditorIntelligence
import LocalModelStore
import Penumbra
import SwiftUI

struct IDEPreferencesEditorPane: View {
    @Bindable var preferences: IDEPreferences
    @State private var modelsStore = IDELocalModelsStore.shared
    @State private var inlineModelStatus = "Not loaded"
    @State private var inlineModelStatusIsError = false
    @State private var isLoadingInlineModel = false
    @State private var inlineLoadGeneration = 0
    /// Set when a download is started from this pane, so the finished model becomes the completion model.
    @State private var selectModelWhenInstalled: String?
    @State private var inlineModelSearchAttempted = false
    @State private var inlineTokenDraft = ""

    @AppStorage(IDEInspectionWidget.defaultsKey) private var showsInspectionWidget = true

    /// Whether the caret follows the theme's text color, holding the custom color otherwise.
    private func caretMatchesThemeBinding() -> Binding<Bool> {
        Binding(
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
        )
    }

    private func caretColorBinding(fallback: UInt32) -> Binding<UInt32> {
        Binding(
            get: { preferences.caretColorHex ?? fallback },
            set: { preferences.caretColorHex = $0 }
        )
    }

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

            IDESettingsToggle(
                "Font Ligatures",
                isOn: $preferences.fontLigatures,
                detail: "Shows sequences like != and -> as one symbol when the font has ligatures (JetBrains Mono, Fira Code, Cascadia Code)."
            )

            IDEPreferencesStepper(
                title: "Font Size",
                value: $preferences.fontSize,
                range: 9...32,
                step: 1,
                fractionLength: 0,
                valueWidth: 24
            )

            IDEPreferencesStepper(
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
                isOn: caretMatchesThemeBinding(),
                detail: "Uses the theme's text color. Turn this off to pick a color."
            )

            if let customCaretColor = preferences.caretColorHex {
                IDESettingsColorWell(
                    title: "Color",
                    hex: caretColorBinding(fallback: customCaretColor)
                )
            }

            IDESettingsToggle("Blink Caret", isOn: $preferences.caretBlinks)

            IDEPreferencesStepper(
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
            IDEPreferencesStepper(
                title: "Tab Width",
                value: $preferences.tabWidth,
                range: 2...8,
                valueWidth: 16
            )

            IDESettingsToggle("Indent with Spaces", isOn: $preferences.useSpacesForTab)
        }

        IDESettingsSection(
            "Smart Keys",
            footer: "Pairs are completed where it makes sense: not in front of a word, and not after one for quotes. Closing tags apply to HTML and XML."
        ) {
            IDESettingsToggle(
                "Insert Paired Brackets",
                isOn: $preferences.insertPairedBrackets,
                detail: "Completes (), [] and {} as you type, and <> after a generic type name such as List."
            )
            IDESettingsToggle("Insert Paired Quotes", isOn: $preferences.insertPairedQuotes)
            IDESettingsToggle(
                "Insert Closing Brace on Enter",
                isOn: $preferences.insertClosingBraceOnEnter,
                detail: "Adds the } when Enter follows a { that nothing closes."
            )
            IDESettingsToggle("Insert Closing Tag on Tag Completion", isOn: $preferences.insertClosingTagOnTagCompletion)
            IDESettingsToggle("Auto-Close Tag on Typing \"</\"", isOn: $preferences.autoCloseTagOnSlash)
        }

        IDESettingsSection(
            "Layout",
            footer: "The vertical scrollbar appears when the minimap is off. Hover the scrollbar, or the minimap outside the visible area, to see code that is off screen. Click to jump to the first line in the popup."
        ) {
            IDESettingsToggle("Line Numbers", isOn: $preferences.showLineNumbers)
            IDESettingsToggle("Code Folding", isOn: $preferences.isLineFoldingEnabled)
            IDESettingsToggle("Word Wrap", isOn: $preferences.wrapLines)
            IDESettingsToggle("Minimap", isOn: $preferences.showMinimap)
            IDESettingsToggle("Scrollbars", isOn: $preferences.showScrollbars)
            IDESettingsToggle("Code Preview on Scrollbar Hover", isOn: $preferences.showEditorFragmentPreview)
        }

        IDESettingsSection(
            "Guides",
            footer: "Method separators draw a hairline between declarations. Invisible characters show tabs and spaces."
        ) {
            IDESettingsToggle("Right Margin", isOn: $preferences.showPageGuide)

            IDEPreferencesStepper(
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
            "External Changes",
            footer: "When an open file changes on disk. Unsaved edits are never replaced without asking, and saving over a newer file always asks first."
        ) {
            IDESettingsPicker("Changed Files", selection: $preferences.externalChangePolicy) {
                ForEach(IDEExternalChangePolicy.allCases) { policy in
                    Text(policy.displayName).tag(policy)
                }
            }
        }

        IDESettingsSection(
            "Sticky Lines",
            footer: "While you scroll, the headers of the classes, methods and blocks around the top line stay pinned. Click one to jump to it; right-click for these settings."
        ) {
            IDESettingsToggle("Show Sticky Lines", isOn: $preferences.showStickyLines)

            IDEPreferencesStepper(
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

            IDESettingsToggle(
                "Problem Counts in Java and Swift Editors", isOn: $showsInspectionWidget,
                detail: "A badge at the top right of a Java or Swift file with its errors and warnings. Click it to open them."
            )

            IDEPreferencesStepper(
                title: "Stripe Mark Height",
                value: $preferences.errorStripeMarkMinHeight,
                range: 1...8,
                valueWidth: 28,
                valueSuffix: " pt"
            )
            .disabled(!preferences.showsErrorStripe)

            IDESettingsToggle("Highlight Current Scope", isOn: $preferences.highlightsCurrentScope)
            IDESettingsToggle("Documentation on Hover", isOn: $preferences.showsDocumentationOnHover)

            IDEPreferencesStepper(
                title: "Tooltip Delay",
                value: $preferences.tooltipDelayMilliseconds,
                range: 0...2000,
                step: 50,
                valueWidth: 56,
                valueSuffix: " ms"
            )

            IDEPreferencesStepper(
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
            "Code Completion",
            footer: "Command completion offers refactorings and editor actions after .., and as a separate group after a single dot. In a read-only file, a dot opens navigation commands instead of editing."
        ) {
            IDESettingsToggle("Command Completion", isOn: $preferences.commandCompletion.isEnabled)
            IDESettingsToggle(
                "Show Commands as a Separate Group", isOn: $preferences.commandCompletion.showsSeparateGroup,
                detail: "Commands appear in their own section at the end of the list after a single dot."
            )
            .disabled(!preferences.commandCompletion.isEnabled)
            IDESettingsToggle(
                "Command Completion in Read-Only Files", isOn: $preferences.commandCompletion.readOnlyEnabled,
                detail: "Typing a dot in a read-only file (such as attached JDK sources) filters navigation commands without editing the file."
            )
            .disabled(!preferences.commandCompletion.isEnabled)

            IDESettingsToggle(
                "Full Line Completion (Local Model)", isOn: $preferences.inlineCompletionEnabled,
                detail: "Gray inline suggestions from a model running on this Mac. Nothing is sent anywhere; the model loads only when this is on."
            )
            if preferences.inlineCompletionEnabled {
                inlineModelRows
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
            footer: "Umbra defaults to Sublime Text shortcuts. Switch to IntelliJ if that is what your muscle memory expects. Picking a Go to File key replaces the double-tap Shift trigger."
        ) {
            IDESettingsPicker("Keymap", selection: $preferences.keymapPreset) {
                ForEach(KeymapPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            IDESettingsPicker("Go to File", selection: $preferences.goToFileShortcut) {
                ForEach(GoToFileShortcut.allCases) { shortcut in
                    Text(shortcut.title).tag(shortcut)
                }
            }
        }
    }

    @ViewBuilder private var inlineModelRows: some View {
        let installed = modelsStore.installed
        let recommendedID = IDEInlineCompletionService.recommendedModelID
        Group {
            IDESettingsPicker("Model", selection: $preferences.inlineCompletionModelID) {
                Text("None").tag(String?.none)
                ForEach(installed) { model in
                    Text(inlineModelMenuTitle(model, among: installed)).tag(String?.some(model.id))
                }
            }
            inlineMemoryRow(installed: installed)
            if let download = modelsStore.download {
                inlineDownloadRow(download)
            }
            if let error = modelsStore.downloadError {
                Text(error)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !installed.contains(where: { $0.id == recommendedID }), modelsStore.download?.id != recommendedID {
                IDESettingsRow("Recommended Model") {
                    Button("Download Qwen2.5-Coder 1.5B (≈0.9 GB)") {
                        beginInlineModelDownload(recommendedID)
                    }
                    .controlSize(.small)
                    .disabled(!modelsStore.canStartDownload)
                }
            }
            inlineModelSearch
            IDESettingsToggle("Java", isOn: .constant(true), detail: "Validated against the Java index: unknown references are cut, and a missing import is added on accept.")
                .disabled(true)
            IDESettingsToggle("Other Languages", isOn: $preferences.inlineCompletionOtherLanguages, detail: "Unvalidated suggestions in other languages.")
            IDESettingsToggle("Multi-Line Suggestions", isOn: $preferences.inlineCompletionMultiLine)
            IDESettingsToggle(
                "Synchronize Inline and Popup Completions", isOn: $preferences.inlineCompletionSyncWithPopup,
                detail: "The current suggestion also appears as the popup's first item."
            )
            IDESettingsPicker("Accept With", selection: $preferences.inlineCompletionAcceptKey) {
                ForEach(InlineAcceptKey.allCases, id: \.self) { key in
                    Text(key.title).tag(key)
                }
            }
        }
        .task {
            modelsStore.prepareIfNeeded()
            let generation = inlineLoadGeneration
            let text = await IDEInlineCompletionService.shared.statusText()
            guard generation == inlineLoadGeneration else { return }
            inlineModelStatus = text
            inlineModelStatusIsError = false
        }
        .onChange(of: modelsStore.installed.map(\.id)) { _, ids in
            guard let pending = selectModelWhenInstalled, ids.contains(pending) else { return }
            preferences.inlineCompletionModelID = pending
            selectModelWhenInstalled = nil
        }
        .onChange(of: modelsStore.download?.id) { previous, next in
            guard let pending = selectModelWhenInstalled, previous == pending, next != pending else { return }
            if !modelsStore.installed.contains(where: { $0.id == pending }) {
                selectModelWhenInstalled = nil
            }
        }
    }

    private func inlineMemoryRow(installed: [InstalledLocalModel]) -> some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            if modelsStore.availability != .available {
                Text(MLXAvailability.message(for: modelsStore.availability))
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            IDESettingsRow("In Memory") {
                HStack(spacing: IDEAppearance.Spacing.sm) {
                    if isLoadingInlineModel {
                        ProgressView().controlSize(.small)
                    }
                    Text(inlineModelStatus)
                        .font(IDEAppearance.Typography.monoCaption)
                        .foregroundStyle(inlineStatusColor)
                        .lineLimit(2)
                    Button("Load", action: loadInlineModel)
                        .controlSize(.small)
                        .disabled(!canLoadInlineModel(installed: installed))
                        .help(inlineLoadHelp(installed: installed))
                    Button("Unload", action: unloadInlineModel)
                        .controlSize(.small)
                        .disabled(!inlineModelStatus.hasPrefix("Loaded") && !isLoadingInlineModel)
                        .help("Free the memory. The next suggestion loads the model again.")
                }
            }
        }
    }

    private var inlineStatusColor: Color {
        if inlineModelStatusIsError { return IDEAppearance.ColorToken.error }
        if inlineModelStatus.hasPrefix("Loaded") { return IDEAppearance.ColorToken.run }
        return IDEAppearance.ColorToken.muted
    }

    private func canLoadInlineModel(installed: [InstalledLocalModel]) -> Bool {
        guard !isLoadingInlineModel, modelsStore.availability == .available else { return false }
        guard let id = preferences.inlineCompletionModelID else { return false }
        return installed.contains { $0.id == id }
    }

    private func inlineLoadHelp(installed: [InstalledLocalModel]) -> String {
        if modelsStore.availability != .available {
            return MLXAvailability.message(for: modelsStore.availability)
        }
        guard let id = preferences.inlineCompletionModelID else { return "Choose a model first." }
        guard installed.contains(where: { $0.id == id }) else { return "Download the model before loading it." }
        return "Load the model into memory now. Leaving it unloaded waits until the first suggestion."
    }

    private func loadInlineModel() {
        inlineLoadGeneration += 1
        let generation = inlineLoadGeneration
        isLoadingInlineModel = true
        inlineModelStatus = "Loading…"
        inlineModelStatusIsError = false
        Task {
            let status = await IDEInlineCompletionService.shared.loadChosenModel()
            guard generation == inlineLoadGeneration else { return }
            inlineModelStatus = status.text
            inlineModelStatusIsError = status.isError
            isLoadingInlineModel = false
        }
    }

    private func unloadInlineModel() {
        inlineLoadGeneration += 1
        isLoadingInlineModel = false
        IDEInlineCompletionService.shared.unload()
        inlineModelStatus = "Not loaded"
        inlineModelStatusIsError = false
    }

    private func inlineDownloadRow(_ download: IDELocalModelsStore.Download) -> some View {
        IDESettingsRow(download.isPaused ? "Paused" : "Downloading") {
            VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
                Text(download.id)
                    .font(IDEAppearance.Typography.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let fraction = download.progress.fractionCompleted {
                    ProgressView(value: fraction).frame(width: 220)
                } else {
                    ProgressView().progressViewStyle(.linear).frame(width: 220)
                }
                Text(download.progress.detailText)
                    .font(IDEAppearance.Typography.monoCaption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                HStack(spacing: IDEAppearance.Spacing.sm) {
                    if download.isPaused {
                        Button("Resume") { modelsStore.resumeDownload() }.controlSize(.small)
                    } else {
                        Button("Pause") { modelsStore.pauseDownload() }.controlSize(.small)
                    }
                    Button("Cancel") { modelsStore.cancelDownload() }.controlSize(.small)
                }
            }
        }
    }

    private var inlineModelSearch: some View {
        @Bindable var modelsStore = modelsStore
        return VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            Text("Find a Model")
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
            HStack(spacing: IDEAppearance.Spacing.sm) {
                TextField("Search Hugging Face for an MLX model", text: $modelsStore.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(searchInlineModels)
                Button("Search", action: searchInlineModels)
                    .controlSize(.small)
                    .disabled(modelsStore.isSearching || modelsStore.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if modelsStore.isSearching { ProgressView().controlSize(.small) }
            }
            Text("Search and download use the network only when you ask. Running the model does not.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let error = modelsStore.searchError {
                Text(error)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if inlineModelSearchAttempted, !modelsStore.isSearching, modelsStore.searchError == nil, modelsStore.results.isEmpty {
                Text("No MLX text models match.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            ForEach(modelsStore.results) { result in
                inlineSearchResultRow(result)
            }
            if modelsStore.results.contains(where: \.isGated), !modelsStore.hasToken {
                inlineGatedTokenRow
            }
        }
    }

    private func searchInlineModels() {
        inlineModelSearchAttempted = true
        Task { await modelsStore.search() }
    }

    private func inlineSearchResultRow(_ result: HFModelSummary) -> some View {
        let installed = modelsStore.installed.contains { $0.id == result.id }
        let isSelected = preferences.inlineCompletionModelID == result.id
        return HStack(alignment: .center, spacing: IDEAppearance.Spacing.sm) {

            VStack(alignment: .leading, spacing: 2) {
                Text(LocalModelFormat.shortName(result.id))
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                    .lineLimit(1)
                Text(inlineSearchSubtitle(result))
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(result.isGated ? IDEAppearance.ColorToken.error : IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: IDEAppearance.Spacing.sm)
            inlineSearchAction(result, installed: installed, isSelected: isSelected)
        }
        .padding(IDEAppearance.Spacing.sm)
        .background(
            isSelected ? IDEAppearance.ColorToken.controlHover : IDEAppearance.ColorToken.card,
            in: .rect(cornerRadius: IDEAppearance.Radius.card)
        )
    }

    @ViewBuilder
    private func inlineSearchAction(_ result: HFModelSummary, installed: Bool, isSelected: Bool) -> some View {
        if installed {
            if isSelected {
                Label("Selected", systemImage: "checkmark")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.run)
            } else {
                Button("Use") { preferences.inlineCompletionModelID = result.id }
                    .controlSize(.small)
                    .help("Use this model for full line completion")
            }
        } else if modelsStore.download?.id == result.id {
            Text(modelsStore.download?.isPaused == true ? "Paused" : "Downloading")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        } else {
            Button("Download") { beginInlineModelDownload(result.id) }
                .controlSize(.small)
                .disabled(inlineDownloadDisabled(result))
                .help(inlineDownloadHelp(result))
        }
    }

    private var inlineGatedTokenRow: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            HStack(spacing: IDEAppearance.Spacing.sm) {
                SecureField("Hugging Face read token", text: $inlineTokenDraft)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    modelsStore.saveToken(inlineTokenDraft)
                    inlineTokenDraft = ""
                }
                .controlSize(.small)
                .disabled(inlineTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("A gated model needs a read token after you accept its license on huggingface.co. The token stays in the Keychain.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func inlineSearchSubtitle(_ result: HFModelSummary) -> String {
        var parts: [String] = []
        let owner = LocalModelFormat.owner(result.id)
        if !owner.isEmpty { parts.append(owner) }
        if let count = result.parameterCount { parts.append(LocalModelFormat.parameters(count)) }
        if let quantization = result.quantization { parts.append(quantization) }
        parts.append("\(LocalModelFormat.compactCount(result.downloads)) downloads")
        if result.isGated { parts.append("gated") }
        return parts.joined(separator: " · ")
    }

    private func inlineDownloadDisabled(_ result: HFModelSummary) -> Bool {
        !modelsStore.canStartDownload || (result.isGated && !modelsStore.hasToken)
    }

    private func inlineDownloadHelp(_ result: HFModelSummary) -> String {
        if result.isGated, !modelsStore.hasToken {
            return "Accept the license on huggingface.co and save a read token below."
        }
        if !modelsStore.canStartDownload { return "One download at a time." }
        return "Download this model and select it for full line completion."
    }

    private func beginInlineModelDownload(_ id: String) {
        guard modelsStore.canStartDownload else { return }
        selectModelWhenInstalled = id
        modelsStore.startDownload(id)
    }

    private func inlineModelMenuTitle(_ model: InstalledLocalModel, among installed: [InstalledLocalModel]) -> String {
        let name = LocalModelFormat.shortName(model.id)
        let collision = installed.contains { $0.id != model.id && LocalModelFormat.shortName($0.id) == name }
        return collision ? model.id : name
    }
}
