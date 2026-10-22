import SwiftUI

struct IDEPreferencesLiveUpdateModifier: ViewModifier {
    @Bindable var preferences: IDEPreferences
    let workspace: IDEWorkspace

    // Split into groups: one 22-modifier chain exceeds the type checker's time limit.
    func body(content: Content) -> some View {
        smartKeyChanges(codeInsightChanges(modeChanges(displayChanges(editingChanges(appearanceChanges(content))))))
    }

    private func smartKeyChanges(_ view: some View) -> some View {
        view
            .onChange(of: preferences.insertPairedBrackets) { applyLivePreferences() }
            .onChange(of: preferences.insertPairedQuotes) { applyLivePreferences() }
            .onChange(of: preferences.insertClosingBraceOnEnter) { applyLivePreferences() }
            .onChange(of: preferences.insertClosingTagOnTagCompletion) { applyLivePreferences() }
            .onChange(of: preferences.autoCloseTagOnSlash) { applyLivePreferences() }
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
            .onChange(of: preferences.goToFileShortcut) { applyLivePreferences() }
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
            .onChange(of: preferences.showEditorFragmentPreview) { applyLivePreferences() }
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
            .onChange(of: preferences.isFocusModeToolbarFadeEnabled) { applyLivePreferences() }
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
