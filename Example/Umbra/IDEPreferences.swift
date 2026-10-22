import AppKit
import CoreText
import EditorIntelligence
import JavaIntelligence
import Observation
import Penumbra
import SwiftUI

@MainActor
@Observable
public final class IDEPreferences {
    public static let shared = IDEPreferences()

    private enum Keys {
        static let fontSize = "com.umbra.editor.fontSize"
        static let fontName = "com.umbra.editor.fontName"
        static let fontLigatures = "com.umbra.editor.fontLigatures"
        static let uiFontName = "com.umbra.editor.uiFontName"
        static let uiFontSize = "com.umbra.editor.uiFontSize"
        static let welcomeBackground = "com.umbra.editor.welcomeBackground"
        static let welcomeAnimationDisabled = "com.umbra.editor.welcomeAnimationDisabled"
        static let uiColorSchemeID = "com.umbra.editor.uiColorSchemeID"
        static let themeID = "com.umbra.editor.themeID"
        static let caretShape = "com.umbra.editor.caretShape"
        static let caretColorHex = "com.umbra.editor.caretColorHex"
        static let caretBlinks = "com.umbra.editor.caretBlinks"
        static let caretBlinkIntervalMilliseconds = "com.umbra.editor.caretBlinkIntervalMilliseconds"
        static let smoothCaretBlinking = "com.umbra.editor.smoothCaretBlinking"
        static let smoothCaretMovement = "com.umbra.editor.smoothCaretMovement"
        static let scaleMarkdownHeadings = "com.umbra.editor.scaleMarkdownHeadings"
        static let tabWidth = "com.umbra.editor.tabWidth"
        static let useSpacesForTab = "com.umbra.editor.useSpacesForTab"
        static let wrapLines = "com.umbra.editor.wrapLines"
        static let showLineNumbers = "com.umbra.editor.showLineNumbers"
        static let isLineFoldingEnabled = "com.umbra.editor.isLineFoldingEnabled"
        static let showMinimap = "com.umbra.editor.showMinimap"
        static let showScrollbars = "com.umbra.editor.showScrollbars"
        static let showEditorFragmentPreview = "com.umbra.editor.showEditorFragmentPreview"
        static let flattenJavaPackages = "com.umbra.editor.flattenJavaPackages"
        static let javaPostfix = "com.umbra.editor.javaPostfix"
        static let commandCompletion = "com.umbra.editor.commandCompletion"
        static let inlineCompletionEnabled = "com.umbra.editor.inlineCompletionEnabled"
        static let inlineCompletionModel = "com.umbra.editor.inlineCompletionModel"
        static let inlineCompletionMultiLine = "com.umbra.editor.inlineCompletionMultiLine"
        static let inlineCompletionSync = "com.umbra.editor.inlineCompletionSync"
        static let inlineCompletionOtherLanguages = "com.umbra.editor.inlineCompletionOtherLanguages"
        static let inlineCompletionAcceptKey = "com.umbra.editor.inlineCompletionAcceptKey"
        static let explorerAutoReveal = "com.umbra.editor.explorerAutoReveal"
        static let explorerSortOrder = "com.umbra.editor.explorerSortOrder"
        static let explorerFoldersOnTop = "com.umbra.editor.explorerFoldersOnTop"
        static let explorerCompactMiddlePackages = "com.umbra.editor.explorerCompactMiddlePackages"
        static let explorerShowExcludedFiles = "com.umbra.editor.explorerShowExcludedFiles"
        static let metalRendering = "com.umbra.editor.metalRendering"
        static let keymapPreset = "com.umbra.editor.keymapPreset"
        static let goToFileShortcut = "com.umbra.editor.goToFileShortcut"
        static let openFoldersIn = "com.umbra.editor.openFoldersIn"
        static let showMethodSeparators = "com.umbra.editor.showMethodSeparators"
        static let highlightsOccurrencesOfSelection = "com.umbra.editor.highlightsOccurrencesOfSelection"
        static let insertPairedBrackets = "com.umbra.editor.insertPairedBrackets"
        static let insertPairedQuotes = "com.umbra.editor.insertPairedQuotes"
        static let insertClosingBraceOnEnter = "com.umbra.editor.insertClosingBraceOnEnter"
        static let insertClosingTagOnTagCompletion = "com.umbra.editor.insertClosingTagOnTagCompletion"
        static let autoCloseTagOnSlash = "com.umbra.editor.autoCloseTagOnSlash"
        static let markModifiedTabs = "com.umbra.editor.markModifiedTabs"
        static let saveOnFocusLoss = "com.umbra.editor.saveOnFocusLoss"
        static let saveWhenIdle = "com.umbra.editor.saveWhenIdle"
        static let idleSaveSeconds = "com.umbra.editor.idleSaveSeconds"
        static let reformatOnSave = "com.umbra.editor.reformatOnSave"
        static let reformatsWholeFileOnSave = "com.umbra.editor.reformatsWholeFileOnSave"
        static let codeCleanupOnSave = "com.umbra.editor.codeCleanupOnSave"
        static let keepsTrailingWhitespaceOnCaretLine = "com.umbra.editor.keepsTrailingWhitespaceOnCaretLine"
        static let ensureNewlineAtEndOfFile = "com.umbra.editor.ensureNewlineAtEndOfFile"
        static let buildProjectOnSave = "com.umbra.editor.buildProjectOnSave"
        static let stripTrailingWhitespaceOnSave = "com.umbra.editor.stripTrailingWhitespaceOnSave"
        static let showInvisibleCharacters = "com.umbra.editor.showInvisibleCharacters"
        static let showPageGuide = "com.umbra.editor.showPageGuide"
        static let pageGuideColumn = "com.umbra.editor.pageGuideColumn"
        static let lineHeightMultiplier = "com.umbra.editor.lineHeightMultiplier"
        static let isTypewriterScrollingEnabled = "com.umbra.editor.isTypewriterScrollingEnabled"
        static let isDistractionFreeModeEnabled = "com.umbra.editor.isDistractionFreeModeEnabled"
        static let isFocusModeEnabled = "com.umbra.editor.isFocusModeEnabled"
        static let isFocusModeToolbarFadeEnabled = "com.umbra.editor.isFocusModeToolbarFadeEnabled"
        static let hasCompletedFirstRunGuide = "com.umbra.editor.hasCompletedFirstRunGuide"
        static let javaGradleAutoSync = "com.umbra.editor.javaGradleAutoSync"
        static let javaMavenAutoRead = "com.umbra.editor.javaMavenAutoRead"
        static let javaMavenDownloadDependencies = "com.umbra.editor.javaMavenDownloadDependencies"
        static let javaMavenExecutable = "com.umbra.editor.javaMavenExecutable"
        static let javaMavenSettingsFile = "com.umbra.editor.javaMavenSettingsFile"
        static let javaCompilerDiagnostics = "com.umbra.editor.javaCompilerDiagnostics"
        static let semanticHighlighting = "com.umbra.editor.semanticHighlighting"
        static let javaInlayHints = "com.umbra.editor.javaInlayHints"
        static let javaInlayVariableTypes = "com.umbra.editor.javaInlayVariableTypes"
        static let javaInlayLambdaTypes = "com.umbra.editor.javaInlayLambdaTypes"
        static let javaCodeVisionUsages = "com.umbra.editor.javaCodeVisionUsages"
        static let javaCoverageShowsInEditor = "com.umbra.editor.javaCoverageShowsInEditor"
        static let javaCoverageIncludesTests = "com.umbra.editor.javaCoverageIncludesTests"
        static let javaCoveragePackageFilter = "com.umbra.editor.javaCoveragePackageFilter"
        static let javaCoverageClearsOnRun = "com.umbra.editor.javaCoverageClearsOnRun"
        static let javaCoverageOpensWindow = "com.umbra.editor.javaCoverageOpensWindow"
        static let javaProfileSamplePeriod = "com.umbra.editor.javaProfileSamplePeriod"
        static let javaProfileOpensRecording = "com.umbra.editor.javaProfileOpensRecording"
        static let javaProfileConfirmMegabytes = "com.umbra.editor.javaProfileConfirmMegabytes"
        static let javaProfileSettings = "com.umbra.editor.javaProfileSettings"
        static let javaProfileShowsLiveCharts = "com.umbra.editor.javaProfileShowsLiveCharts"
        static let javaProfileLineHints = "com.umbra.editor.javaProfileLineHints"
        static let javaProfileSettingsFile = "com.umbra.editor.javaProfileSettingsFile"
        static let javaProfileStackDepth = "com.umbra.editor.javaProfileStackDepth"
        static let javaProfileAllocationRate = "com.umbra.editor.javaProfileAllocationRate"
        static let javaProfileWaitThreshold = "com.umbra.editor.javaProfileWaitThreshold"
        static let javaCodeVisionImplementations = "com.umbra.editor.javaCodeVisionImplementations"
        static let inlayHintsUseEditorFont = "com.umbra.editor.inlayHintsUseEditorFont"
        static let javaDisabledGutterIcons = "com.umbra.editor.javaDisabledGutterIcons"
        static let javaDisabledIntentions = "com.umbra.editor.javaDisabledIntentions"
        static let javaShowIntentionBulb = "com.umbra.editor.javaShowIntentionBulb"
        static let javaShowIntentionPreview = "com.umbra.editor.javaShowIntentionPreview"
        static let javaDisabledInspections = "com.umbra.editor.javaDisabledInspections"
        static let javaInspectionSeverities = "com.umbra.editor.javaInspectionSeverities"
        static let javaInspectionLimits = "com.umbra.editor.javaInspectionLimits"
        static let javaTreatsPublicApiAsUsed = "com.umbra.editor.javaTreatsPublicApiAsUsed"
        static let javaOptimizeImportsOnSave = "com.umbra.editor.javaOptimizeImportsOnSave"
        static let javaAddUnambiguousImports = "com.umbra.editor.javaAddUnambiguousImports"
        static let javaInsertImportsOnPaste = "com.umbra.editor.javaInsertImportsOnPaste"
        static let javaUseSingleClassImports = "com.umbra.editor.javaUseSingleClassImports"
        static let javaClassCountToUseStarImport = "com.umbra.editor.javaClassCountToUseStarImport"
        static let javaStaticCountToUseStarImport = "com.umbra.editor.javaStaticCountToUseStarImport"
        static let javaImportExclusions = "com.umbra.editor.javaImportExclusions"
        static let javaStaticMemberClasses = "com.umbra.editor.javaStaticMemberClasses"
        static let javaGradleSyncTimeoutSeconds = "com.umbra.editor.javaGradleSyncTimeoutSeconds"
        static let javaMavenGoalTimeoutSeconds = "com.umbra.editor.javaMavenGoalTimeoutSeconds"
        static let javaDecompilerAgreementAccepted = "com.umbra.editor.javaDecompilerAgreementAccepted"
        static let showsErrorStripe = "com.umbra.editor.showsErrorStripe"
        static let errorStripeMarkMinHeight = "com.umbra.editor.errorStripeMarkMinHeight"
        static let highlightsCurrentScope = "com.umbra.editor.highlightsCurrentScope"
        static let showStickyLines = "com.umbra.editor.showStickyLines"
        static let externalChangePolicy = "com.umbra.editor.externalChangePolicy"
        static let maximumStickyLines = "com.umbra.editor.maximumStickyLines"
        static let runTemporaryConfigurationLimit = "com.umbra.editor.runTemporaryConfigurationLimit"
        static let stickyLinesDisabledLanguages = "com.umbra.editor.stickyLinesDisabledLanguages"
        static let showsDocumentationOnHover = "com.umbra.editor.showsDocumentationOnHover"
        static let tooltipDelayMilliseconds = "com.umbra.editor.tooltipDelayMilliseconds"
        /// AppKit's own key for how long a native tooltip waits, in milliseconds.
        static let nativeTooltipDelay = "NSInitialToolTipDelay"
        static let autoreparseDelayMilliseconds = "com.umbra.editor.autoreparseDelayMilliseconds"
        static let nextErrorScope = "com.umbra.editor.nextErrorScope"
        static let inPlaceRefactoring = "com.umbra.editor.inPlaceRefactoring"
        static let preselectsRenamedName = "com.umbra.editor.preselectsRenamedName"
        static let confirmsInlineVariable = "com.umbra.editor.confirmsInlineVariable"
        static let javaSuppressWithComment = "com.umbra.editor.javaSuppressWithComment"
        /// The same keys `IDELocalHistoryRecorder` already reads. Not the `com.umbra.editor` prefix.
        static let localHistoryDays = "umbra.localHistory.days"
        static let localHistoryMegabytes = "umbra.localHistory.megabytes"
    }

    var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: Keys.fontSize); applyTheme() }
    }

    var fontName: String {
        didSet { UserDefaults.standard.set(fontName, forKey: Keys.fontName); applyTheme() }
    }

    /// Draws sequences such as `!=` and `->` as one symbol in fonts that have ligatures.
    var fontLigatures: Bool {
        didSet { UserDefaults.standard.set(fontLigatures, forKey: Keys.fontLigatures); applyTheme() }
    }

    var uiFontName: String {
        didSet {
            UserDefaults.standard.set(uiFontName, forKey: Keys.uiFontName)
            IDEUIFonts.setCurrentFamilyName(uiFontName)
        }
    }

    var uiFontSize: Double {
        didSet {
            UserDefaults.standard.set(uiFontSize, forKey: Keys.uiFontSize)
            IDEUIFonts.setCurrentFontSize(uiFontSize)
        }
    }

    /// Animated backdrop of the welcome page.
    var welcomeBackground: IDEWelcomeBackground {
        didSet { UserDefaults.standard.set(welcomeBackground.rawValue, forKey: Keys.welcomeBackground) }
    }

    /// Holds the welcome backdrop still, as if Reduce Motion were on, without changing the system setting.
    var welcomeAnimationDisabled: Bool {
        didSet { UserDefaults.standard.set(welcomeAnimationDisabled, forKey: Keys.welcomeAnimationDisabled) }
    }

    /// Shell chrome colors (sidebars, tabs, panels). Editor syntax themes are separate.
    var uiColorSchemeID: String {
        didSet {
            UserDefaults.standard.set(uiColorSchemeID, forKey: Keys.uiColorSchemeID)
            IDEAppearance.applyUIColorScheme(uiColorScheme)
        }
    }

    var uiColorScheme: IDEUIColorScheme {
        IDEUIColorSchemeCatalog.scheme(id: uiColorSchemeID)
    }

    var themeID: String {
        didSet { UserDefaults.standard.set(themeID, forKey: Keys.themeID); applyTheme() }
    }

    /// Bar, block, or underline. The bar is the thin vertical caret.
    var caretShape: CaretShape {
        didSet { UserDefaults.standard.set(caretShape.rawValue, forKey: Keys.caretShape) }
    }

    /// Custom caret color. `nil` follows the theme's text color.
    var caretColorHex: UInt32? {
        didSet {
            if let caretColorHex {
                UserDefaults.standard.set(Int(caretColorHex), forKey: Keys.caretColorHex)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.caretColorHex)
            }
        }
    }

    /// Whether the caret blinks. Off keeps it solid.
    var caretBlinks: Bool {
        didSet { UserDefaults.standard.set(caretBlinks, forKey: Keys.caretBlinks) }
    }

    /// How long the caret stays visible, and then hidden, in a blink cycle (milliseconds).
    var caretBlinkIntervalMilliseconds: Int {
        didSet { UserDefaults.standard.set(caretBlinkIntervalMilliseconds, forKey: Keys.caretBlinkIntervalMilliseconds) }
    }

    /// Fade the caret in and out instead of switching it.
    var smoothCaretBlinking: Bool {
        didSet { UserDefaults.standard.set(smoothCaretBlinking, forKey: Keys.smoothCaretBlinking) }
    }

    /// Glide the caret to its new position instead of jumping.
    var smoothCaretMovement: Bool {
        didSet { UserDefaults.standard.set(smoothCaretMovement, forKey: Keys.smoothCaretMovement) }
    }

    /// Renders markdown headings (H1–H6) at progressively larger sizes in the editor.
    var scaleMarkdownHeadings: Bool {
        didSet { UserDefaults.standard.set(scaleMarkdownHeadings, forKey: Keys.scaleMarkdownHeadings); applyTheme() }
    }

    var tabWidth: Int {
        didSet { UserDefaults.standard.set(tabWidth, forKey: Keys.tabWidth) }
    }

    var useSpacesForTab: Bool {
        didSet { UserDefaults.standard.set(useSpacesForTab, forKey: Keys.useSpacesForTab) }
    }

    var wrapLines: Bool {
        didSet { UserDefaults.standard.set(wrapLines, forKey: Keys.wrapLines) }
    }

    var showLineNumbers: Bool {
        didSet { UserDefaults.standard.set(showLineNumbers, forKey: Keys.showLineNumbers) }
    }

    var isLineFoldingEnabled: Bool {
        didSet { UserDefaults.standard.set(isLineFoldingEnabled, forKey: Keys.isLineFoldingEnabled) }
    }

    var showMinimap: Bool {
        didSet { UserDefaults.standard.set(showMinimap, forKey: Keys.showMinimap) }
    }

    /// Floating overlay scrollbars. The vertical one only appears while the minimap is off, since
    /// the minimap's viewport indicator already serves that role.
    var showScrollbars: Bool {
        didSet { UserDefaults.standard.set(showScrollbars, forKey: Keys.showScrollbars) }
    }

    /// Hover the scrollbar, or the minimap outside the visible area, to preview off-screen code.
    var showEditorFragmentPreview: Bool {
        didSet { UserDefaults.standard.set(showEditorFragmentPreview, forKey: Keys.showEditorFragmentPreview) }
    }

    /// Explorer shows each Java source root's packages as flat dotted rows (IntelliJ's
    /// "Flatten Packages") instead of nested folders.
    var flattenJavaPackages: Bool {
        didSet { UserDefaults.standard.set(flattenJavaPackages, forKey: Keys.flattenJavaPackages) }
    }

    /// Command completion (`..`, the command section of `.`, read-only files).
    var commandCompletion: CommandCompletionSettings {
        didSet {
            guard let data = try? JSONEncoder().encode(commandCompletion) else { return }
            UserDefaults.standard.set(data, forKey: Keys.commandCompletion)
        }
    }

    /// Full-line (inline) completion with a local model. Machine-local, like the model
    /// choice itself; not part of the synced snapshot.
    var inlineCompletionEnabled: Bool {
        didSet { UserDefaults.standard.set(inlineCompletionEnabled, forKey: Keys.inlineCompletionEnabled) }
    }
    var inlineCompletionModelID: String? {
        didSet { UserDefaults.standard.set(inlineCompletionModelID, forKey: Keys.inlineCompletionModel) }
    }
    var inlineCompletionMultiLine: Bool {
        didSet { UserDefaults.standard.set(inlineCompletionMultiLine, forKey: Keys.inlineCompletionMultiLine) }
    }
    var inlineCompletionSyncWithPopup: Bool {
        didSet { UserDefaults.standard.set(inlineCompletionSyncWithPopup, forKey: Keys.inlineCompletionSync) }
    }
    var inlineCompletionOtherLanguages: Bool {
        didSet { UserDefaults.standard.set(inlineCompletionOtherLanguages, forKey: Keys.inlineCompletionOtherLanguages) }
    }
    var inlineCompletionAcceptKey: InlineAcceptKey {
        didSet { UserDefaults.standard.set(inlineCompletionAcceptKey.rawValue, forKey: Keys.inlineCompletionAcceptKey) }
    }

    /// Postfix templates, the key that expands one, and user-written templates.
    var javaPostfix: JavaPostfixConfiguration {
        didSet {
            guard let data = try? JSONEncoder().encode(javaPostfix) else { return }
            UserDefaults.standard.set(data, forKey: Keys.javaPostfix)
        }
    }

    /// Explorer selects and scrolls to the active editor tab's file whenever the tab changes.
    var explorerAutoReveal: Bool {
        didSet { UserDefaults.standard.set(explorerAutoReveal, forKey: Keys.explorerAutoReveal) }
    }

    /// Explorer row order within a folder: by name, or by file extension then name.
    var explorerSortOrder: IDEExplorerSortOrder {
        didSet { UserDefaults.standard.set(explorerSortOrder.rawValue, forKey: Keys.explorerSortOrder) }
    }

    /// Explorer lists folders above files. Off intermixes them in one sorted list.
    var explorerFoldersOnTop: Bool {
        didSet { UserDefaults.standard.set(explorerFoldersOnTop, forKey: Keys.explorerFoldersOnTop) }
    }

    /// Explorer joins chains of single-child folders under a source root into one dotted row
    /// (IntelliJ's "Compact Middle Packages").
    var explorerCompactMiddlePackages: Bool {
        didSet { UserDefaults.standard.set(explorerCompactMiddlePackages, forKey: Keys.explorerCompactMiddlePackages) }
    }

    /// Explorer lists build outputs (dimmed). Off hides them.
    var explorerShowExcludedFiles: Bool {
        didSet { UserDefaults.standard.set(explorerShowExcludedFiles, forKey: Keys.explorerShowExcludedFiles) }
    }

    var isMetalRenderingEnabled: Bool {
        didSet { UserDefaults.standard.set(isMetalRenderingEnabled, forKey: Keys.metalRendering) }
    }

    var keymapPreset: KeymapPreset {
        didSet { UserDefaults.standard.set(keymapPreset.rawValue, forKey: Keys.keymapPreset) }
    }

    /// The key that opens Go to File. One trigger at a time: picking a key replaces the
    /// double-tap Shift trigger. Machine-local (like which folders open where), so it stays
    /// out of the exported preferences snapshot.
    var goToFileShortcut: GoToFileShortcut {
        didSet { UserDefaults.standard.set(goToFileShortcut.rawValue, forKey: Keys.goToFileShortcut) }
    }

    /// What opening a folder from a window that already has a project does. Not part of the
    /// preferences snapshot: it stays on this Mac.
    var openFoldersIn: IDEOpenFoldersIn {
        didSet { UserDefaults.standard.set(openFoldersIn.rawValue, forKey: Keys.openFoldersIn) }
    }

    var showMethodSeparators: Bool {
        didSet { UserDefaults.standard.set(showMethodSeparators, forKey: Keys.showMethodSeparators) }
    }

    var highlightsOccurrencesOfSelection: Bool {
        didSet {
            UserDefaults.standard.set(highlightsOccurrencesOfSelection, forKey: Keys.highlightsOccurrencesOfSelection)
        }
    }

    // MARK: Smart keys (IntelliJ's Editor > General > Smart Keys)

    /// `()`, `[]`, `{}` as you type, and `<>` after a generic type name.
    var insertPairedBrackets: Bool {
        didSet { UserDefaults.standard.set(insertPairedBrackets, forKey: Keys.insertPairedBrackets) }
    }

    var insertPairedQuotes: Bool {
        didSet { UserDefaults.standard.set(insertPairedQuotes, forKey: Keys.insertPairedQuotes) }
    }

    /// Enter after a `{` that nothing closes adds the `}`.
    var insertClosingBraceOnEnter: Bool {
        didSet { UserDefaults.standard.set(insertClosingBraceOnEnter, forKey: Keys.insertClosingBraceOnEnter) }
    }

    /// HTML and XML: typing the `>` of a start tag adds the end tag.
    var insertClosingTagOnTagCompletion: Bool {
        didSet { UserDefaults.standard.set(insertClosingTagOnTagCompletion, forKey: Keys.insertClosingTagOnTagCompletion) }
    }

    /// HTML and XML: typing `</` completes the innermost open tag.
    var autoCloseTagOnSlash: Bool {
        didSet { UserDefaults.standard.set(autoCloseTagOnSlash, forKey: Keys.autoCloseTagOnSlash) }
    }

    /// Marks a tab, the Explorer row and the window's close button while the file has unsaved
    /// changes (IntelliJ's Editor Tabs ▸ Mark modified).
    var markModifiedTabs: Bool {
        didSet { UserDefaults.standard.set(markModifiedTabs, forKey: Keys.markModifiedTabs) }
    }

    /// Saves every unsaved file when Umbra stops being the active app or the terminal gets focus.
    var saveOnFocusLoss: Bool {
        didSet { UserDefaults.standard.set(saveOnFocusLoss, forKey: Keys.saveOnFocusLoss) }
    }

    /// Saves every unsaved file once typing has paused for `idleSaveSeconds`.
    var saveWhenIdle: Bool {
        didSet { UserDefaults.standard.set(saveWhenIdle, forKey: Keys.saveWhenIdle) }
    }

    var idleSaveSeconds: Int {
        didSet {
            let clamped = min(max(idleSaveSeconds, Self.idleSaveSecondsRange.lowerBound), Self.idleSaveSecondsRange.upperBound)
            if clamped != idleSaveSeconds { idleSaveSeconds = clamped; return }
            UserDefaults.standard.set(idleSaveSeconds, forKey: Keys.idleSaveSeconds)
        }
    }


    /// Reformat code (the language's formatter) on every save.
    var reformatOnSave: Bool {
        didSet { UserDefaults.standard.set(reformatOnSave, forKey: Keys.reformatOnSave) }
    }

    /// Reformat the whole file instead of only the lines changed since the last commit.
    var reformatsWholeFileOnSave: Bool {
        didSet { UserDefaults.standard.set(reformatsWholeFileOnSave, forKey: Keys.reformatsWholeFileOnSave) }
    }

    /// Apply the active inspection profile's quick fixes (Java) on every save.
    var codeCleanupOnSave: Bool {
        didSet { UserDefaults.standard.set(codeCleanupOnSave, forKey: Keys.codeCleanupOnSave) }
    }

    /// Leave trailing spaces on the caret's line, where the user is still typing.
    var keepsTrailingWhitespaceOnCaretLine: Bool {
        didSet { UserDefaults.standard.set(keepsTrailingWhitespaceOnCaretLine, forKey: Keys.keepsTrailingWhitespaceOnCaretLine) }
    }

    /// End every saved file with a line break.
    var ensureNewlineAtEndOfFile: Bool {
        didSet { UserDefaults.standard.set(ensureNewlineAtEndOfFile, forKey: Keys.ensureNewlineAtEndOfFile) }
    }

    /// Run Build Project after the user saves.
    var buildProjectOnSave: Bool {
        didSet { UserDefaults.standard.set(buildProjectOnSave, forKey: Keys.buildProjectOnSave) }
    }

    /// Which lines lose their trailing spaces and tabs on save.
    var stripTrailingWhitespaceOnSave: IDEStripWhitespaceScope {
        didSet { UserDefaults.standard.set(stripTrailingWhitespaceOnSave.rawValue, forKey: Keys.stripTrailingWhitespaceOnSave) }
    }

    static let idleSaveSecondsRange = 1...300
    static let defaultIdleSaveSeconds = 15

    // MARK: Code insight (IntelliJ's Editor > General)
    // Kept on this Mac, not in the preferences snapshot, like the Java settings.

    /// A tick per problem along the trailing edge, over the minimap or the scrollbar.
    var showsErrorStripe: Bool {
        didSet { UserDefaults.standard.set(showsErrorStripe, forKey: Keys.showsErrorStripe) }
    }

    /// Shortest error stripe tick, in points.
    var errorStripeMarkMinHeight: Int {
        didSet { UserDefaults.standard.set(errorStripeMarkMinHeight, forKey: Keys.errorStripeMarkMinHeight) }
    }

    /// A bar in the fold ribbon beside the block the caret is in.
    var highlightsCurrentScope: Bool {
        didSet { UserDefaults.standard.set(highlightsCurrentScope, forKey: Keys.highlightsCurrentScope) }
    }

    /// What a text tab does when its file changes on disk (Settings ▸ Editor ▸ External Changes).
    /// Kept on this Mac.
    var externalChangePolicy: IDEExternalChangePolicy {
        didSet { UserDefaults.standard.set(externalChangePolicy.rawValue, forKey: Keys.externalChangePolicy) }
    }

    /// Pins the headers of the blocks around the first visible line (class, method, `if`, loop) to
    /// the top of the editor while their bodies scroll by. Kept on this Mac, like the other code insight settings.
    var showStickyLines: Bool {
        didSet { UserDefaults.standard.set(showStickyLines, forKey: Keys.showStickyLines) }
    }

    /// The most lines sticky lines pin at once (1...10).
    /// How many temporary run configurations a project keeps (Settings ▸ Java ▸ Run); kept on this Mac.
    var runTemporaryConfigurationLimit: Int {
        didSet {
            UserDefaults.standard.set(runTemporaryConfigurationLimit, forKey: Keys.runTemporaryConfigurationLimit)
            IDESharedServices.shared.runConfigurations.temporaryLimit = runTemporaryConfigurationLimit
        }
    }

    var maximumStickyLines: Int {
        didSet { UserDefaults.standard.set(maximumStickyLines, forKey: Keys.maximumStickyLines) }
    }

    /// Language identifiers sticky lines are switched off for, from "Disable for <language>".
    var stickyLinesDisabledLanguages: [String] {
        didSet { UserDefaults.standard.set(stickyLinesDisabledLanguages, forKey: Keys.stickyLinesDisabledLanguages) }
    }

    /// Documentation of the symbol under the pointer once it rests.
    var showsDocumentationOnHover: Bool {
        didSet { UserDefaults.standard.set(showsDocumentationOnHover, forKey: Keys.showsDocumentationOnHover) }
    }

    /// How long the pointer or caret rests before a tooltip or documentation popup shows. Also the
    /// delay of the fold preview and, through ``applyNativeTooltipDelay()``, of AppKit's own tooltips
    /// (gutter icons, toolbar buttons).
    var tooltipDelayMilliseconds: Int {
        didSet {
            UserDefaults.standard.set(tooltipDelayMilliseconds, forKey: Keys.tooltipDelayMilliseconds)
            applyNativeTooltipDelay()
        }
    }

    /// How long typing pauses before the document is re-read for diagnostics, symbols and inspections.
    var autoreparseDelayMilliseconds: Int {
        didSet { UserDefaults.standard.set(autoreparseDelayMilliseconds, forKey: Keys.autoreparseDelayMilliseconds) }
    }

    /// Which problems Next / Previous Problem (F2) stops at.
    var nextErrorScope: ProblemNavigationScope {
        didSet { UserDefaults.standard.set(nextErrorScope.rawValue, forKey: Keys.nextErrorScope) }
    }

    /// Rename and Extract mark the affected code in the editor and apply without a preview when
    /// nothing needs a decision.
    var inPlaceRefactoring: Bool {
        didSet { UserDefaults.standard.set(inPlaceRefactoring, forKey: Keys.inPlaceRefactoring) }
    }

    /// The rename field opens with the old name selected, so typing replaces it.
    var preselectsRenamedName: Bool {
        didSet { UserDefaults.standard.set(preselectsRenamedName, forKey: Keys.preselectsRenamedName) }
    }

    /// Inline Variable previews its changes before applying them.
    var confirmsInlineVariable: Bool {
        didSet { UserDefaults.standard.set(confirmsInlineVariable, forKey: Keys.confirmsInlineVariable) }
    }

    /// Suppress quick fixes add a `//noinspection` comment instead of `@SuppressWarnings`.
    var javaSuppressWithComment: Bool {
        didSet { UserDefaults.standard.set(javaSuppressWithComment, forKey: Keys.javaSuppressWithComment) }
    }

    var showInvisibleCharacters: Bool {
        didSet { UserDefaults.standard.set(showInvisibleCharacters, forKey: Keys.showInvisibleCharacters) }
    }

    var showPageGuide: Bool {
        didSet { UserDefaults.standard.set(showPageGuide, forKey: Keys.showPageGuide) }
    }

    var pageGuideColumn: Int {
        didSet { UserDefaults.standard.set(pageGuideColumn, forKey: Keys.pageGuideColumn) }
    }

    var lineHeightMultiplier: Double {
        didSet { UserDefaults.standard.set(lineHeightMultiplier, forKey: Keys.lineHeightMultiplier) }
    }

    var isTypewriterScrollingEnabled: Bool {
        didSet { UserDefaults.standard.set(isTypewriterScrollingEnabled, forKey: Keys.isTypewriterScrollingEnabled) }
    }

    var isDistractionFreeModeEnabled: Bool {
        didSet { UserDefaults.standard.set(isDistractionFreeModeEnabled, forKey: Keys.isDistractionFreeModeEnabled) }
    }

    var isFocusModeEnabled: Bool {
        didSet { UserDefaults.standard.set(isFocusModeEnabled, forKey: Keys.isFocusModeEnabled) }
    }

    var isFocusModeToolbarFadeEnabled: Bool {
        didSet { UserDefaults.standard.set(isFocusModeToolbarFadeEnabled, forKey: Keys.isFocusModeToolbarFadeEnabled) }
    }

    /// The preset's bindings with the Go to File override applied.
    var keymap: Keymap {
        var map = keymapPreset.keymap
        goToFileShortcut.apply(to: &map)
        return map
    }

    var hasCompletedFirstRunGuide: Bool {
        didSet { UserDefaults.standard.set(hasCompletedFirstRunGuide, forKey: Keys.hasCompletedFirstRunGuide) }
    }

    /// When a Gradle project opens, resolve modules and dependencies automatically. Still gated by
    /// the trust prompt. Machine-local: not part of `IDEPreferencesSnapshot`.
    var javaGradleAutoSync: Bool {
        didSet { UserDefaults.standard.set(javaGradleAutoSync, forKey: Keys.javaGradleAutoSync) }
    }

    /// Read `pom.xml` when a Maven project opens. Reading does not run Maven. Machine-local.
    var javaMavenAutoRead: Bool {
        didSet { UserDefaults.standard.set(javaMavenAutoRead, forKey: Keys.javaMavenAutoRead) }
    }

    /// After a read, download dependencies that are not in the local repository. Runs Maven, so it
    /// still asks for trust. Machine-local.
    var javaMavenDownloadDependencies: Bool {
        didSet { UserDefaults.standard.set(javaMavenDownloadDependencies, forKey: Keys.javaMavenDownloadDependencies) }
    }

    /// A Maven executable to use when the project has no `mvnw`. Empty uses `mvn` on `PATH`.
    var javaMavenExecutable: String {
        didSet { UserDefaults.standard.set(javaMavenExecutable, forKey: Keys.javaMavenExecutable) }
    }

    /// A `settings.xml` to pass as `mvn -s`. Empty uses Maven's own lookup. Machine-local.
    var javaMavenSettingsFile: String {
        didSet { UserDefaults.standard.set(javaMavenSettingsFile, forKey: Keys.javaMavenSettingsFile) }
    }

    /// Check open Java files with the JDK's `javac` and list the errors as Problems. Runs only in
    /// folders that are not Gradle projects, or in Gradle projects that have synced (which needs the
    /// trust prompt to be accepted). Machine-local: not part of `IDEPreferencesSnapshot`.
    /// Show parameter names before call arguments in Java files (`count: 3`). Off by default:
    /// it resolves calls in the background as you type. Machine-local: not part of `IDEPreferencesSnapshot`.
    var javaInlayHints: Bool {
        didSet { UserDefaults.standard.set(javaInlayHints, forKey: Keys.javaInlayHints) }
    }

    /// `var items`: the type after a `var` local or loop variable.
    var javaInlayVariableTypes: Bool {
        didSet { UserDefaults.standard.set(javaInlayVariableTypes, forKey: Keys.javaInlayVariableTypes) }
    }

    /// `(a, b) -> …`: the types of implicitly typed lambda parameters.
    var javaInlayLambdaTypes: Bool {
        didSet { UserDefaults.standard.set(javaInlayLambdaTypes, forKey: Keys.javaInlayLambdaTypes) }
    }

    /// Paints covered, partly covered and missed lines of the last coverage run in the editor.
    var javaCoverageShowsInEditor: Bool {
        didSet { UserDefaults.standard.set(javaCoverageShowsInEditor, forKey: Keys.javaCoverageShowsInEditor) }
    }

    /// Includes the test source sets in the coverage report.
    var javaCoverageIncludesTests: Bool {
        didSet { UserDefaults.standard.set(javaCoverageIncludesTests, forKey: Keys.javaCoverageIncludesTests) }
    }

    /// Package prefixes (separated by commas or spaces) the coverage report is limited to; empty
    /// reports on every package of the project.
    var javaCoveragePackageFilter: String {
        didSet { UserDefaults.standard.set(javaCoveragePackageFilter, forKey: Keys.javaCoveragePackageFilter) }
    }

    /// The prefixes of ``javaCoveragePackageFilter``.
    var javaCoveragePackagePrefixes: [String] {
        javaCoveragePackageFilter.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map(String.init)
    }

    /// Removes the previous run's coverage when the next run starts, instead of keeping it until
    /// the new report is ready.
    var javaCoverageClearsOnRun: Bool {
        didSet { UserDefaults.standard.set(javaCoverageClearsOnRun, forKey: Keys.javaCoverageClearsOnRun) }
    }

    /// Opens the Coverage tab when a report is ready.
    var javaCoverageOpensWindow: Bool {
        didSet { UserDefaults.standard.set(javaCoverageOpensWindow, forKey: Keys.javaCoverageOpensWindow) }
    }

    /// The CPU sample period in milliseconds; 0 keeps the `profile` setting's 10 ms. Java 17 and later.
    var javaProfileSamplePeriod: Int {
        didSet { UserDefaults.standard.set(javaProfileSamplePeriod, forKey: Keys.javaProfileSamplePeriod) }
    }

    /// Shows each line's share of the profile beside the code, and tints the hottest lines.
    var javaProfileLineHints: Bool {
        didSet { UserDefaults.standard.set(javaProfileLineHints, forKey: Keys.javaProfileLineHints) }
    }

    /// Opens the profiler tab when a profiled run starts, with live CPU and memory charts.
    var javaProfileShowsLiveCharts: Bool {
        didSet { UserDefaults.standard.set(javaProfileShowsLiveCharts, forKey: Keys.javaProfileShowsLiveCharts) }
    }

    /// `profile`, `default` or `custom` (the `.jfc` file below): which JFR settings a profiled run uses.
    var javaProfileSettings: String {
        didSet { UserDefaults.standard.set(javaProfileSettings, forKey: Keys.javaProfileSettings) }
    }

    /// The `.jfc` file the `custom` setting names.
    var javaProfileSettingsFile: String {
        didSet { UserDefaults.standard.set(javaProfileSettingsFile, forKey: Keys.javaProfileSettingsFile) }
    }

    /// Frames kept per stack; JFR's own default is 64, which cuts deep framework stacks.
    var javaProfileStackDepth: Int {
        didSet { UserDefaults.standard.set(javaProfileStackDepth, forKey: Keys.javaProfileStackDepth) }
    }

    /// Allocation samples per second; 0 keeps the setting's 150. Java 17 and later.
    var javaProfileAllocationRate: Int {
        didSet { UserDefaults.standard.set(javaProfileAllocationRate, forKey: Keys.javaProfileAllocationRate) }
    }

    /// The shortest wait (ms) a profile records; 0 keeps the setting's. Java 17 and later.
    var javaProfileWaitThreshold: Int {
        didSet { UserDefaults.standard.set(javaProfileWaitThreshold, forKey: Keys.javaProfileWaitThreshold) }
    }

    /// What a profiled run records, from the settings above.
    func currentFlightRecorderOptions() -> JavaFlightRecorderOptions {
        var options = JavaFlightRecorderOptions()
        switch javaProfileSettings {
        case "default": options.template = .standard
        case "custom" where !javaProfileSettingsFile.isEmpty: options.template = .custom(path: javaProfileSettingsFile)
        default: options.template = .profile
        }
        options.samplePeriodMilliseconds = javaProfileSamplePeriod > 0 ? javaProfileSamplePeriod : nil
        options.stackDepth = javaProfileStackDepth
        options.allocationSamplesPerSecond = javaProfileAllocationRate > 0 ? javaProfileAllocationRate : nil
        options.waitThresholdMilliseconds = javaProfileWaitThreshold > 0 ? javaProfileWaitThreshold : nil
        return options
    }

    /// Opens a profiled run's recording in the profiler when the run ends.
    var javaProfileOpensRecording: Bool {
        didSet { UserDefaults.standard.set(javaProfileOpensRecording, forKey: Keys.javaProfileOpensRecording) }
    }

    /// A recording larger than this many megabytes asks before it is read.
    var javaProfileConfirmMegabytes: Int {
        didSet { UserDefaults.standard.set(javaProfileConfirmMegabytes, forKey: Keys.javaProfileConfirmMegabytes) }
    }

    /// `3 usages` above classes, methods and constructors. A search per declaration, so off by default.
    var javaCodeVisionUsages: Bool {
        didSet { UserDefaults.standard.set(javaCodeVisionUsages, forKey: Keys.javaCodeVisionUsages) }
    }

    /// `2 implementations` above interfaces, abstract classes and abstract methods.
    var javaCodeVisionImplementations: Bool {
        didSet { UserDefaults.standard.set(javaCodeVisionImplementations, forKey: Keys.javaCodeVisionImplementations) }
    }

    /// Whether any code vision label is on, which is when the editor makes room above declarations.
    var areCodeVisionLensesEnabled: Bool {
        javaCodeVisionUsages || javaCodeVisionImplementations
    }

    /// The labels the Java provider produces, read from the defaults at call time (it is an actor).
    nonisolated static func currentJavaCodeVisionOptions() -> JavaCodeVisionOptions {
        let defaults = UserDefaults.standard
        return JavaCodeVisionOptions(
            usages: defaults.bool(forKey: Keys.javaCodeVisionUsages),
            implementations: defaults.bool(forKey: Keys.javaCodeVisionImplementations)
        )
    }

    /// Whether any kind of inlay hint is on, which is when the editor asks for hints at all.
    var areInlayHintsEnabled: Bool {
        javaInlayHints || javaInlayVariableTypes || javaInlayLambdaTypes
    }

    /// One level of indentation as the editor is set up (`tabWidth` spaces, or a tab), for the language
    /// services (`LanguageEnvironment.indentUnit`), which run off the main actor.
    nonisolated static func currentIndentUnit() async -> String {
        await MainActor.run {
            let preferences = IDEPreferences.shared
            return preferences.useSpacesForTab ? String(repeating: " ", count: max(1, preferences.tabWidth)) : "\t"
        }
    }

    /// Which Java intentions are on, read from the defaults at call time so the provider (an actor)
    /// sees a change without waiting for the settings view.
    nonisolated static func currentJavaIntentionOptions() -> JavaIntentionOptions {
        let defaults = UserDefaults.standard
        return JavaIntentionOptions.restored(
            disabledIDs: defaults.stringArray(forKey: Keys.javaDisabledIntentions),
            showsBulb: defaults.object(forKey: Keys.javaShowIntentionBulb) as? Bool,
            showsPreview: defaults.object(forKey: Keys.javaShowIntentionPreview) as? Bool
        )
    }

    /// The hint kinds the Java provider produces, read from the defaults at call time so the provider
    /// (an actor, off the main thread) always sees the current settings.
    nonisolated static func currentJavaInlayHintOptions() -> JavaInlayHintOptions {
        let defaults = UserDefaults.standard
        return JavaInlayHintOptions(
            parameterNames: defaults.bool(forKey: Keys.javaInlayHints),
            variableTypes: defaults.bool(forKey: Keys.javaInlayVariableTypes),
            lambdaParameterTypes: defaults.bool(forKey: Keys.javaInlayLambdaTypes)
        )
    }

    /// Draws inlay hints in the editor font instead of the system UI font.
    var inlayHintsUseEditorFont: Bool {
        didSet { UserDefaults.standard.set(inlayHintsUseEditorFont, forKey: Keys.inlayHintsUseEditorFont) }
    }

    var javaCompilerDiagnostics: Bool {
        didSet { UserDefaults.standard.set(javaCompilerDiagnostics, forKey: Keys.javaCompilerDiagnostics) }
    }

    /// Java gutter icons the user turned off (every kind is on by default). Machine-local: not
    /// part of `IDEPreferencesSnapshot`.
    var javaDisabledGutterIcons: Set<JavaLineMarkerKind> {
        didSet { UserDefaults.standard.set(javaDisabledGutterIcons.map(\.rawValue).sorted(), forKey: Keys.javaDisabledGutterIcons) }
    }

    var enabledJavaGutterIcons: Set<JavaLineMarkerKind> {
        Set(JavaLineMarkerKind.allCases).subtracting(javaDisabledGutterIcons)
    }

    /// Intention ids the user turned off. Every intention starts on; only the deviations are stored.
    var javaDisabledIntentions: Set<String> {
        didSet { UserDefaults.standard.set(javaDisabledIntentions.sorted(), forKey: Keys.javaDisabledIntentions) }
    }

    /// The yellow or red bulb beside the caret line in a Java file.
    var javaShowIntentionBulb: Bool {
        didSet { UserDefaults.standard.set(javaShowIntentionBulb, forKey: Keys.javaShowIntentionBulb) }
    }

    /// The lines an intention would write, beside the context-action list.
    var javaShowIntentionPreview: Bool {
        didSet { UserDefaults.standard.set(javaShowIntentionPreview, forKey: Keys.javaShowIntentionPreview) }
    }

    /// Codes of the Java inspections the user turned off (the rules that start switched off are
    /// listed too). This and the next three keys are the "Default" inspection profile
    /// (`IDEInspectionProfiles`). Stored by code so a renamed enum case cannot lose a choice.
    /// Machine-local: not part of `IDEPreferencesSnapshot`.
    var javaDisabledInspections: Set<String> {
        didSet { UserDefaults.standard.set(javaDisabledInspections.sorted(), forKey: Keys.javaDisabledInspections) }
    }

    /// Severity per inspection code, only where it differs from the rule's default.
    var javaInspectionSeverities: [String: String] {
        didSet { UserDefaults.standard.set(javaInspectionSeverities, forKey: Keys.javaInspectionSeverities) }
    }

    /// The user's threshold per metric rule code (maximum complexity, nesting, …), only where it differs from the default.
    var javaInspectionLimits: [String: Int] {
        didSet { UserDefaults.standard.set(javaInspectionLimits, forKey: Keys.javaInspectionLimits) }
    }

    /// Public and protected members are API someone else may call, so the project-wide rules leave
    /// them alone. Off for an application whose code nothing outside uses.
    var javaTreatsPublicApiAsUsed: Bool {
        didSet { UserDefaults.standard.set(javaTreatsPublicApiAsUsed, forKey: Keys.javaTreatsPublicApiAsUsed) }
    }

    var javaInspectionThresholds: JavaInspectionThresholds {
        var values: [JavaInspectionRule: Int] = [:]
        for rule in JavaInspectionRule.allCases where rule.limit != nil {
            if let value = javaInspectionLimits[rule.code] { values[rule] = value }
        }
        return JavaInspectionThresholds(values)
    }

    func limit(of rule: JavaInspectionRule) -> Int { javaInspectionThresholds.value(for: rule) }

    func setLimit(_ value: Int, for rule: JavaInspectionRule) {
        guard let limit = rule.limit else { return }
        let clamped = min(max(value, limit.range.lowerBound), limit.range.upperBound)
        javaInspectionLimits[rule.code] = clamped == limit.defaultValue ? nil : clamped
    }

    /// Codes of the rules that start switched off.
    static var defaultDisabledInspections: Set<String> {
        Set(JavaInspectionRule.allCases.filter { !$0.isEnabledByDefault }.map(\.code))
    }

    var enabledJavaInspections: Set<JavaInspectionRule> {
        Set(JavaInspectionRule.allCases.filter { !javaDisabledInspections.contains($0.code) })
    }

    var javaInspectionSeverityOverrides: [JavaInspectionRule: JavaInspection.Severity] {
        var overrides: [JavaInspectionRule: JavaInspection.Severity] = [:]
        for rule in JavaInspectionRule.allCases {
            if let raw = javaInspectionSeverities[rule.code], let severity = JavaInspection.Severity(rawValue: raw) {
                overrides[rule] = severity
            }
        }
        return overrides
    }

    func isEnabled(_ rule: JavaInspectionRule) -> Bool { !javaDisabledInspections.contains(rule.code) }

    func setEnabled(_ isEnabled: Bool, for rule: JavaInspectionRule) {
        if isEnabled { javaDisabledInspections.remove(rule.code) } else { javaDisabledInspections.insert(rule.code) }
    }

    func severity(of rule: JavaInspectionRule) -> JavaInspection.Severity {
        javaInspectionSeverityOverrides[rule] ?? rule.defaultSeverity
    }

    func setSeverity(_ severity: JavaInspection.Severity, for rule: JavaInspectionRule) {
        if severity == rule.defaultSeverity {
            javaInspectionSeverities[rule.code] = nil
        } else {
            javaInspectionSeverities[rule.code] = severity.rawValue
        }
    }

    func resetJavaInspections() {
        javaDisabledInspections = Self.defaultDisabledInspections
        javaInspectionSeverities = [:]
        javaInspectionLimits = [:]
        javaTreatsPublicApiAsUsed = true
    }

    /// Colour Java identifiers by what they are (types by kind, methods, fields, parameters, locals)
    /// on top of the syntax highlighting. Machine-local: not part of `IDEPreferencesSnapshot`.
    var semanticHighlighting: Bool {
        didSet { UserDefaults.standard.set(semanticHighlighting, forKey: Keys.semanticHighlighting) }
    }

    /// Remove unused imports from a Java file each time it is saved. Off by default: saving never
    /// edits the file unless this is on. Machine-local: not part of `IDEPreferencesSnapshot`.
    var javaOptimizeImportsOnSave: Bool {
        didSet { UserDefaults.standard.set(javaOptimizeImportsOnSave, forKey: Keys.javaOptimizeImportsOnSave) }
    }

    /// Import the one class that can resolve an unresolved simple name once typing pauses.
    /// Machine-local: not part of `IDEPreferencesSnapshot`.
    var javaAddUnambiguousImports: Bool {
        didSet { UserDefaults.standard.set(javaAddUnambiguousImports, forKey: Keys.javaAddUnambiguousImports) }
    }

    /// Insert imports for unresolved types in pasted code. Machine-local: not part of `IDEPreferencesSnapshot`.
    var javaInsertImportsOnPaste: Bool {
        didSet { UserDefaults.standard.set(javaInsertImportsOnPaste, forKey: Keys.javaInsertImportsOnPaste) }
    }

    /// Off writes `import pkg.*` as soon as a second class from that package is imported.
    /// Machine-local: not part of `IDEPreferencesSnapshot`.
    var javaUseSingleClassImports: Bool {
        didSet { UserDefaults.standard.set(javaUseSingleClassImports, forKey: Keys.javaUseSingleClassImports) }
    }

    /// Single-class imports from one package become `import pkg.*` at this count. `999` never does.
    /// Machine-local: not part of `IDEPreferencesSnapshot`.
    var javaClassCountToUseStarImport: Int {
        didSet { UserDefaults.standard.set(javaClassCountToUseStarImport, forKey: Keys.javaClassCountToUseStarImport) }
    }

    /// Static imports from one class become `import static Owner.*` at this count. `999` never does.
    /// Machine-local: not part of `IDEPreferencesSnapshot`.
    var javaStaticCountToUseStarImport: Int {
        didSet { UserDefaults.standard.set(javaStaticCountToUseStarImport, forKey: Keys.javaStaticCountToUseStarImport) }
    }

    /// Classes and packages completion and auto-import will not add, separated by commas or newlines.
    /// Machine-local: not part of `IDEPreferencesSnapshot`.
    var javaImportExclusions: String {
        didSet { UserDefaults.standard.set(javaImportExclusions, forKey: Keys.javaImportExclusions) }
    }

    /// Classes whose public static members completion may import. A leading `-` drops one member.
    /// Machine-local: not part of `IDEPreferencesSnapshot`.
    var javaStaticMemberClasses: String {
        didSet { UserDefaults.standard.set(javaStaticMemberClasses, forKey: Keys.javaStaticMemberClasses) }
    }

    /// The import settings Java completion, quick fixes and on-the-fly insertion share.
    var javaImportPolicy: JavaImportPolicy {
        JavaImportPolicy(
            addUnambiguousImportsOnTheFly: javaAddUnambiguousImports,
            insertImportsOnPaste: javaInsertImportsOnPaste ? .always : .never,
            useSingleClassImports: javaUseSingleClassImports,
            classCountToUseStarImport: javaClassCountToUseStarImport,
            staticCountToUseStarImport: javaStaticCountToUseStarImport,
            excluded: JavaImportPolicy.names(in: javaImportExclusions),
            staticMemberClasses: JavaImportPolicy.names(in: javaStaticMemberClasses)
        )
    }

    /// How long one Gradle project-model sync may run before it is killed. A first sync may
    /// download a Gradle distribution, so this sits above `GradleCommandRunner`'s 120s default.
    var javaGradleSyncTimeoutSeconds: Int {
        didSet { UserDefaults.standard.set(javaGradleSyncTimeoutSeconds, forKey: Keys.javaGradleSyncTimeoutSeconds) }
    }

    /// How long one Maven goal may run before it is killed. A `run` goal is not subject to this.
    var javaMavenGoalTimeoutSeconds: Int {
        didSet { UserDefaults.standard.set(javaMavenGoalTimeoutSeconds, forKey: Keys.javaMavenGoalTimeoutSeconds) }
    }

    /// Standing consent for decompiling `.class` files with no attached source using Sunflower
    /// (FernflowerKit). Set once the user accepts ``JavaDecompilerAgreement`` at a Go to
    /// Definition. Machine-local: not part of `IDEPreferencesSnapshot`.
    var javaDecompilerAgreementAccepted: Bool {
        didSet {
            UserDefaults.standard.set(javaDecompilerAgreementAccepted, forKey: Keys.javaDecompilerAgreementAccepted)
        }
    }

    /// How long an unnamed Local History revision is kept. Machine-local: not part of `IDEPreferencesSnapshot`.
    var localHistoryDays: Int {
        didSet {
            let clamped = min(max(localHistoryDays, 1), 365)
            if clamped != localHistoryDays {
                localHistoryDays = clamped
                return
            }
            UserDefaults.standard.set(localHistoryDays, forKey: Keys.localHistoryDays)
        }
    }

    /// How much text Local History keeps, in megabytes. Machine-local: not part of `IDEPreferencesSnapshot`.
    var localHistoryMegabytes: Int {
        didSet {
            let clamped = min(max(localHistoryMegabytes, 50), 10_000)
            if clamped != localHistoryMegabytes {
                localHistoryMegabytes = clamped
                return
            }
            UserDefaults.standard.set(localHistoryMegabytes, forKey: Keys.localHistoryMegabytes)
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        fontSize = defaults.object(forKey: Keys.fontSize) as? Double ?? 13
        fontName = defaults.string(forKey: Keys.fontName) ?? IDEEditorFonts.defaultFamilyName
        fontLigatures = defaults.bool(forKey: Keys.fontLigatures)
        uiFontName = defaults.string(forKey: Keys.uiFontName) ?? IDEUIFonts.defaultFamilyName
        uiFontSize = defaults.object(forKey: Keys.uiFontSize) as? Double ?? IDEUIFonts.defaultFontSize
        welcomeBackground = defaults.string(forKey: Keys.welcomeBackground)
            .flatMap(IDEWelcomeBackground.init(rawValue:)) ?? .moltenMetal
        welcomeAnimationDisabled = defaults.bool(forKey: Keys.welcomeAnimationDisabled)
        let savedUIColorSchemeID = defaults.string(forKey: Keys.uiColorSchemeID)
        uiColorSchemeID = switch savedUIColorSchemeID {
        case "fleet", "fleet-dark-edited": IDEUIColorSchemeCatalog.defaultID
        case let id?: id
        default: IDEUIColorSchemeCatalog.defaultID
        }
        themeID = defaults.string(forKey: Keys.themeID) ?? ThemeCatalog.defaultDarkID
        caretShape = defaults.string(forKey: Keys.caretShape).flatMap(CaretShape.init(rawValue:)) ?? .bar
        if let storedCaretColor = defaults.object(forKey: Keys.caretColorHex) as? NSNumber {
            caretColorHex = UInt32(truncatingIfNeeded: storedCaretColor.intValue)
        } else {
            caretColorHex = nil
        }
        caretBlinks = defaults.object(forKey: Keys.caretBlinks) as? Bool ?? true
        caretBlinkIntervalMilliseconds = defaults.object(forKey: Keys.caretBlinkIntervalMilliseconds) as? Int ?? 500
        smoothCaretBlinking = defaults.object(forKey: Keys.smoothCaretBlinking) as? Bool ?? true
        smoothCaretMovement = defaults.object(forKey: Keys.smoothCaretMovement) as? Bool ?? true
        scaleMarkdownHeadings = defaults.object(forKey: Keys.scaleMarkdownHeadings) as? Bool ?? true
        tabWidth = defaults.object(forKey: Keys.tabWidth) as? Int ?? 4
        useSpacesForTab = defaults.object(forKey: Keys.useSpacesForTab) as? Bool ?? true
        wrapLines = defaults.object(forKey: Keys.wrapLines) as? Bool ?? false
        showLineNumbers = defaults.object(forKey: Keys.showLineNumbers) as? Bool ?? true
        isLineFoldingEnabled = defaults.object(forKey: Keys.isLineFoldingEnabled) as? Bool ?? true
        showMinimap = defaults.object(forKey: Keys.showMinimap) as? Bool ?? true
        showScrollbars = defaults.object(forKey: Keys.showScrollbars) as? Bool ?? true
        showEditorFragmentPreview = defaults.object(forKey: Keys.showEditorFragmentPreview) as? Bool ?? true
        flattenJavaPackages = defaults.object(forKey: Keys.flattenJavaPackages) as? Bool ?? false
        if let data = defaults.data(forKey: Keys.javaPostfix),
           let stored = try? JSONDecoder().decode(JavaPostfixConfiguration.self, from: data) {
            javaPostfix = stored
        } else {
            javaPostfix = .standard
        }
        if let data = defaults.data(forKey: Keys.commandCompletion),
           let stored = try? JSONDecoder().decode(CommandCompletionSettings.self, from: data) {
            commandCompletion = stored
        } else {
            commandCompletion = .standard
        }
        inlineCompletionEnabled = defaults.object(forKey: Keys.inlineCompletionEnabled) as? Bool ?? false
        inlineCompletionModelID = defaults.string(forKey: Keys.inlineCompletionModel)
        inlineCompletionMultiLine = defaults.object(forKey: Keys.inlineCompletionMultiLine) as? Bool ?? false
        inlineCompletionSyncWithPopup = defaults.object(forKey: Keys.inlineCompletionSync) as? Bool ?? false
        inlineCompletionOtherLanguages = defaults.object(forKey: Keys.inlineCompletionOtherLanguages) as? Bool ?? false
        inlineCompletionAcceptKey = defaults.string(forKey: Keys.inlineCompletionAcceptKey).flatMap(InlineAcceptKey.init(rawValue:)) ?? .tab
        explorerAutoReveal = defaults.object(forKey: Keys.explorerAutoReveal) as? Bool ?? true
        explorerSortOrder = defaults.string(forKey: Keys.explorerSortOrder).flatMap(IDEExplorerSortOrder.init(rawValue:)) ?? .name
        explorerFoldersOnTop = defaults.object(forKey: Keys.explorerFoldersOnTop) as? Bool ?? true
        explorerCompactMiddlePackages = defaults.object(forKey: Keys.explorerCompactMiddlePackages) as? Bool ?? true
        explorerShowExcludedFiles = defaults.object(forKey: Keys.explorerShowExcludedFiles) as? Bool ?? true
        isMetalRenderingEnabled = defaults.object(forKey: Keys.metalRendering) as? Bool ?? true
        let presetRaw = defaults.string(forKey: Keys.keymapPreset) ?? KeymapPreset.sublime.rawValue
        keymapPreset = KeymapPreset(rawValue: presetRaw) ?? .sublime
        goToFileShortcut = defaults.string(forKey: Keys.goToFileShortcut).flatMap(GoToFileShortcut.init(rawValue:)) ?? .commandP
        openFoldersIn = defaults.string(forKey: Keys.openFoldersIn).flatMap(IDEOpenFoldersIn.init(rawValue:)) ?? .ask
        showMethodSeparators = defaults.object(forKey: Keys.showMethodSeparators) as? Bool ?? true
        highlightsOccurrencesOfSelection = defaults.object(forKey: Keys.highlightsOccurrencesOfSelection) as? Bool ?? true
        insertPairedBrackets = defaults.object(forKey: Keys.insertPairedBrackets) as? Bool ?? true
        insertPairedQuotes = defaults.object(forKey: Keys.insertPairedQuotes) as? Bool ?? true
        insertClosingBraceOnEnter = defaults.object(forKey: Keys.insertClosingBraceOnEnter) as? Bool ?? true
        insertClosingTagOnTagCompletion = defaults.object(forKey: Keys.insertClosingTagOnTagCompletion) as? Bool ?? true
        autoCloseTagOnSlash = defaults.object(forKey: Keys.autoCloseTagOnSlash) as? Bool ?? true
        markModifiedTabs = defaults.object(forKey: Keys.markModifiedTabs) as? Bool ?? true
        saveOnFocusLoss = defaults.object(forKey: Keys.saveOnFocusLoss) as? Bool ?? true
        saveWhenIdle = defaults.object(forKey: Keys.saveWhenIdle) as? Bool ?? true
        reformatOnSave = defaults.object(forKey: Keys.reformatOnSave) as? Bool ?? false
        reformatsWholeFileOnSave = defaults.object(forKey: Keys.reformatsWholeFileOnSave) as? Bool ?? false
        codeCleanupOnSave = defaults.object(forKey: Keys.codeCleanupOnSave) as? Bool ?? false
        keepsTrailingWhitespaceOnCaretLine = defaults.object(forKey: Keys.keepsTrailingWhitespaceOnCaretLine) as? Bool ?? true
        ensureNewlineAtEndOfFile = defaults.object(forKey: Keys.ensureNewlineAtEndOfFile) as? Bool ?? false
        buildProjectOnSave = defaults.object(forKey: Keys.buildProjectOnSave) as? Bool ?? false
        stripTrailingWhitespaceOnSave = defaults.string(forKey: Keys.stripTrailingWhitespaceOnSave).flatMap(IDEStripWhitespaceScope.init(rawValue:)) ?? .modifiedLines
        idleSaveSeconds = min(max(
            defaults.object(forKey: Keys.idleSaveSeconds) as? Int ?? Self.defaultIdleSaveSeconds,
            Self.idleSaveSecondsRange.lowerBound), Self.idleSaveSecondsRange.upperBound)
        showInvisibleCharacters = defaults.object(forKey: Keys.showInvisibleCharacters) as? Bool ?? false
        showsErrorStripe = defaults.object(forKey: Keys.showsErrorStripe) as? Bool ?? true
        errorStripeMarkMinHeight = defaults.object(forKey: Keys.errorStripeMarkMinHeight) as? Int ?? 2
        highlightsCurrentScope = defaults.object(forKey: Keys.highlightsCurrentScope) as? Bool ?? true
        showStickyLines = defaults.object(forKey: Keys.showStickyLines) as? Bool ?? true
        externalChangePolicy = defaults.string(forKey: Keys.externalChangePolicy)
            .flatMap(IDEExternalChangePolicy.init(rawValue:)) ?? .always
        maximumStickyLines = min(max(defaults.object(forKey: Keys.maximumStickyLines) as? Int ?? 5, 1), 10)
        let temporaryLimit = min(max(
            defaults.object(forKey: Keys.runTemporaryConfigurationLimit) as? Int ?? JavaRunConfigurationStore.defaultTemporaryLimit, 1
        ), 50)
        runTemporaryConfigurationLimit = temporaryLimit
        // A property's observer does not run for its first value, so hand the saved one over here.
        IDESharedServices.shared.runConfigurations.temporaryLimit = temporaryLimit
        stickyLinesDisabledLanguages = defaults.stringArray(forKey: Keys.stickyLinesDisabledLanguages) ?? []
        showsDocumentationOnHover = defaults.object(forKey: Keys.showsDocumentationOnHover) as? Bool ?? true
        let storedTooltipDelay = defaults.object(forKey: Keys.tooltipDelayMilliseconds) as? Int ?? 500
        tooltipDelayMilliseconds = storedTooltipDelay
        defaults.set(storedTooltipDelay, forKey: Keys.nativeTooltipDelay)
        autoreparseDelayMilliseconds = defaults.object(forKey: Keys.autoreparseDelayMilliseconds) as? Int ?? 300
        nextErrorScope = defaults.string(forKey: Keys.nextErrorScope).flatMap(ProblemNavigationScope.init(rawValue:)) ?? .all
        inPlaceRefactoring = defaults.object(forKey: Keys.inPlaceRefactoring) as? Bool ?? true
        preselectsRenamedName = defaults.object(forKey: Keys.preselectsRenamedName) as? Bool ?? true
        confirmsInlineVariable = defaults.object(forKey: Keys.confirmsInlineVariable) as? Bool ?? false
        javaSuppressWithComment = defaults.bool(forKey: Keys.javaSuppressWithComment)
        showPageGuide = defaults.object(forKey: Keys.showPageGuide) as? Bool ?? false
        pageGuideColumn = defaults.object(forKey: Keys.pageGuideColumn) as? Int ?? 120
        lineHeightMultiplier = defaults.object(forKey: Keys.lineHeightMultiplier) as? Double ?? 1.2
        isTypewriterScrollingEnabled = defaults.object(forKey: Keys.isTypewriterScrollingEnabled) as? Bool ?? false
        isDistractionFreeModeEnabled = defaults.object(forKey: Keys.isDistractionFreeModeEnabled) as? Bool ?? false
        isFocusModeEnabled = defaults.object(forKey: Keys.isFocusModeEnabled) as? Bool ?? false
        isFocusModeToolbarFadeEnabled = defaults.object(forKey: Keys.isFocusModeToolbarFadeEnabled) as? Bool ?? false
        hasCompletedFirstRunGuide = defaults.bool(forKey: Keys.hasCompletedFirstRunGuide)
        javaGradleAutoSync = defaults.object(forKey: Keys.javaGradleAutoSync) as? Bool ?? true
        javaMavenAutoRead = defaults.object(forKey: Keys.javaMavenAutoRead) as? Bool ?? true
        javaMavenDownloadDependencies = defaults.object(forKey: Keys.javaMavenDownloadDependencies) as? Bool ?? true
        javaMavenExecutable = defaults.string(forKey: Keys.javaMavenExecutable) ?? ""
        javaMavenSettingsFile = defaults.string(forKey: Keys.javaMavenSettingsFile) ?? ""
        javaCompilerDiagnostics = defaults.object(forKey: Keys.javaCompilerDiagnostics) as? Bool ?? true
        semanticHighlighting = defaults.object(forKey: Keys.semanticHighlighting) as? Bool ?? true
        javaInlayHints = defaults.bool(forKey: Keys.javaInlayHints)
        javaInlayVariableTypes = defaults.bool(forKey: Keys.javaInlayVariableTypes)
        javaInlayLambdaTypes = defaults.bool(forKey: Keys.javaInlayLambdaTypes)
        javaCodeVisionUsages = defaults.bool(forKey: Keys.javaCodeVisionUsages)
        javaCoverageShowsInEditor = defaults.object(forKey: Keys.javaCoverageShowsInEditor) as? Bool ?? true
        javaCoverageIncludesTests = defaults.object(forKey: Keys.javaCoverageIncludesTests) as? Bool ?? false
        javaCoveragePackageFilter = defaults.string(forKey: Keys.javaCoveragePackageFilter) ?? ""
        javaCoverageClearsOnRun = defaults.object(forKey: Keys.javaCoverageClearsOnRun) as? Bool ?? true
        javaCoverageOpensWindow = defaults.object(forKey: Keys.javaCoverageOpensWindow) as? Bool ?? true
        javaProfileSamplePeriod = defaults.object(forKey: Keys.javaProfileSamplePeriod) as? Int ?? 0
        javaProfileOpensRecording = defaults.object(forKey: Keys.javaProfileOpensRecording) as? Bool ?? true
        javaProfileConfirmMegabytes = defaults.object(forKey: Keys.javaProfileConfirmMegabytes) as? Int ?? 500
        javaProfileSettings = defaults.string(forKey: Keys.javaProfileSettings) ?? "profile"
        javaProfileShowsLiveCharts = defaults.object(forKey: Keys.javaProfileShowsLiveCharts) as? Bool ?? true
        javaProfileLineHints = defaults.object(forKey: Keys.javaProfileLineHints) as? Bool ?? true
        javaProfileSettingsFile = defaults.string(forKey: Keys.javaProfileSettingsFile) ?? ""
        javaProfileStackDepth = defaults.object(forKey: Keys.javaProfileStackDepth) as? Int ?? JavaFlightRecorder.defaultStackDepth
        javaProfileAllocationRate = defaults.object(forKey: Keys.javaProfileAllocationRate) as? Int ?? 0
        javaProfileWaitThreshold = defaults.object(forKey: Keys.javaProfileWaitThreshold) as? Int ?? 0
        javaCodeVisionImplementations = defaults.bool(forKey: Keys.javaCodeVisionImplementations)
        inlayHintsUseEditorFont = defaults.bool(forKey: Keys.inlayHintsUseEditorFont)
        javaDisabledGutterIcons = Set((defaults.stringArray(forKey: Keys.javaDisabledGutterIcons) ?? []).compactMap(JavaLineMarkerKind.init(rawValue:)))
        javaDisabledIntentions = Set(defaults.stringArray(forKey: Keys.javaDisabledIntentions) ?? [])
        javaShowIntentionBulb = defaults.object(forKey: Keys.javaShowIntentionBulb) as? Bool ?? true
        javaShowIntentionPreview = defaults.object(forKey: Keys.javaShowIntentionPreview) as? Bool ?? true
        javaDisabledInspections = Set(defaults.stringArray(forKey: Keys.javaDisabledInspections) ?? Array(Self.defaultDisabledInspections))
        javaInspectionSeverities = defaults.dictionary(forKey: Keys.javaInspectionSeverities) as? [String: String] ?? [:]
        javaInspectionLimits = defaults.dictionary(forKey: Keys.javaInspectionLimits) as? [String: Int] ?? [:]
        javaTreatsPublicApiAsUsed = defaults.object(forKey: Keys.javaTreatsPublicApiAsUsed) as? Bool ?? true
        javaOptimizeImportsOnSave = defaults.bool(forKey: Keys.javaOptimizeImportsOnSave)
        javaAddUnambiguousImports = defaults.object(forKey: Keys.javaAddUnambiguousImports) as? Bool ?? true
        javaInsertImportsOnPaste = defaults.object(forKey: Keys.javaInsertImportsOnPaste) as? Bool ?? true
        javaUseSingleClassImports = defaults.object(forKey: Keys.javaUseSingleClassImports) as? Bool ?? true
        javaClassCountToUseStarImport = defaults.object(forKey: Keys.javaClassCountToUseStarImport) as? Int ?? 5
        javaStaticCountToUseStarImport = defaults.object(forKey: Keys.javaStaticCountToUseStarImport) as? Int ?? 3
        javaImportExclusions = defaults.string(forKey: Keys.javaImportExclusions) ?? ""
        javaStaticMemberClasses = defaults.string(forKey: Keys.javaStaticMemberClasses) ?? ""
        javaGradleSyncTimeoutSeconds = defaults.object(forKey: Keys.javaGradleSyncTimeoutSeconds) as? Int ?? 300
        javaMavenGoalTimeoutSeconds = defaults.object(forKey: Keys.javaMavenGoalTimeoutSeconds) as? Int ?? 300
        javaDecompilerAgreementAccepted = defaults.bool(forKey: Keys.javaDecompilerAgreementAccepted)
        localHistoryDays = min(max((defaults.object(forKey: Keys.localHistoryDays) as? NSNumber)?.intValue ?? 7, 1), 365)
        localHistoryMegabytes = min(max((defaults.object(forKey: Keys.localHistoryMegabytes) as? NSNumber)?.intValue ?? 500, 50), 10_000)
        IDEUIFonts.setCurrentFamilyName(uiFontName)
        IDEUIFonts.setCurrentFontSize(uiFontSize)
        IDEAppearance.applyUIColorScheme(uiColorScheme)
        applyTheme()
    }

    /// `repaint` re-typesets the visible lines and gutter, for a Settings change (the theme may be
    /// rebuilt in place, which `TextView.theme` cannot see). Loading a document or switching tabs
    /// passes `false`: that repaint was ~50 ms of every tab switch.
    func apply(to textView: TextView, repaint: Bool = false) {
        textView.indentStrategy = useSpacesForTab ? .space(length: tabWidth) : .tab(length: tabWidth)
        textView.showLineNumbers = showLineNumbers
        // 4 pt more than Penumbra's default, so the numbers (and a breakpoint in place of one)
        // clear the gutter's left edge.
        textView.gutterLeadingPadding = 6
        textView.isLineFoldingEnabled = isLineFoldingEnabled
        textView.isLineWrappingEnabled = wrapLines
        textView.showMinimap = showMinimap
        textView.showsScrollers = showScrollbars
        textView.showsEditorFragmentPreview = showEditorFragmentPreview
        textView.isMetalRenderingEnabled = isMetalRenderingEnabled
        textView.showMethodSeparators = showMethodSeparators
        textView.highlightsOccurrencesOfSelection = highlightsOccurrencesOfSelection
        applySmartKeys(to: textView)
        textView.showsErrorStripe = showsErrorStripe
        textView.errorStripeMinimumMarkHeight = CGFloat(errorStripeMarkMinHeight)
        textView.highlightsCurrentScope = highlightsCurrentScope
        applyStickyLines(to: textView)
        textView.showTabs = showInvisibleCharacters
        textView.showSpaces = showInvisibleCharacters
        textView.showPageGuide = showPageGuide
        textView.pageGuideColumn = pageGuideColumn
        textView.showReformattingGuideShading = false
        textView.lineHeightMultiplier = CGFloat(lineHeightMultiplier)
        textView.isTypewriterScrollingEnabled = isTypewriterScrollingEnabled
        if isTypewriterScrollingEnabled {
            textView.isAutomaticScrollEnabled = true
        }
        textView.isDistractionFreeModeEnabled = isDistractionFreeModeEnabled
        textView.isFocusModeEnabled = isFocusModeEnabled
        textView.focusModeHidesChrome = isFocusModeToolbarFadeEnabled
        textView.keymap = keymap
        textView.doubleShiftOpensQuickOpen = goToFileShortcut.doubleShiftEnabled
        textView.theme = IDEEditorTheme.shared.current
        textView.tooltipDelay = TimeInterval(tooltipDelayMilliseconds) / 1000
        textView.inlayHintsUseEditorFont = inlayHintsUseEditorFont
        textView.caretShape = caretShape
        textView.caretBlinkingEnabled = caretBlinks
        textView.caretBlinkInterval = TimeInterval(caretBlinkIntervalMilliseconds) / 1000
        textView.smoothCaretBlinking = smoothCaretBlinking
        textView.smoothCaretMovement = smoothCaretMovement
        if let caretColorHex {
            textView.insertionPointColor = NSColor(rgb: caretColorHex)
        } else {
            textView.insertionPointColor = textView.theme.textColor
        }
        if repaint {
            textView.redisplayVisibleLines()
            textView.refreshGutterChrome()
        }
    }

    /// Pushes the Smart Keys switches onto `textView` for its language. Call again when the
    /// language changes; `apply(to:)` does it for every preference change and document load.
    func applySmartKeys(to textView: TextView) {
        let configuration = IDESmartKeysConfiguration.make(
            language: textView.languageIdentifier,
            switches: IDESmartKeysConfiguration.Switches(
                insertPairedBrackets: insertPairedBrackets,
                insertPairedQuotes: insertPairedQuotes,
                insertClosingBraceOnEnter: insertClosingBraceOnEnter,
                insertClosingTagOnTagCompletion: insertClosingTagOnTagCompletion,
                autoCloseTagOnSlash: autoCloseTagOnSlash
            )
        )
        if textView.characterPairs.count != configuration.characterPairs.count
            || (textView.characterPairs as? [BasicCharacterPair]) != configuration.characterPairs {
            textView.characterPairs = configuration.characterPairs
        }
        textView.characterPairTrailingComponentDeletionMode = .immediatelyFollowingLeadingComponent
        textView.insertsClosingBraceOnEnter = configuration.insertsClosingBraceOnEnter
        textView.tagAutoClosing = configuration.tagAutoClosing
        textView.voidTagNames = configuration.voidTagNames
    }

    /// Switches sticky lines on for `textView` unless they are off for its language, and wires the
    /// pinned lines' context menu to these settings.
    func applyStickyLines(to textView: TextView) {
        let language = textView.languageIdentifier
        let disabledForLanguage = language.map { stickyLinesDisabledLanguages.contains($0) } ?? false
        textView.showsStickyLines = showStickyLines && !disabledForLanguage
        textView.maximumStickyLineCount = maximumStickyLines
        textView.stickyLinesConfigureHandler = {
            guard let workspace = IDEWindowRegistry.shared.activeWorkspace else { return }
            workspace.requestedSettingsDomain = .editor
            workspace.showSettings()
        }
        textView.stickyLinesDisableHandler = { [weak textView] languageOnly in
            let preferences = IDEPreferences.shared
            if languageOnly, let language = textView?.languageIdentifier {
                if !preferences.stickyLinesDisabledLanguages.contains(language) {
                    preferences.stickyLinesDisabledLanguages.append(language)
                }
            } else {
                preferences.showStickyLines = false
            }
            IDEWindowRegistry.shared.activeWorkspace?.applyPreferencesToAllHosts()
        }
    }

    /// AppKit reads `NSInitialToolTipDelay` (milliseconds) from the app's own defaults for every
    /// native tooltip and SwiftUI `.help`. It is an undocumented key, so only the host app writes
    /// it, never the library; AppKit may read it once, in which case a change applies after a relaunch.
    func applyNativeTooltipDelay() {
        UserDefaults.standard.set(tooltipDelayMilliseconds, forKey: Keys.nativeTooltipDelay)
    }

    /// Applies the code-insight settings to a pane's intelligence controller.
    func apply(to controller: EditorIntelligenceController) {
        controller.showsDocumentationOnMouseHover = showsDocumentationOnHover
        controller.tooltipDelay = TimeInterval(tooltipDelayMilliseconds) / 1000
        controller.codeVisionConfiguration = "\(javaCodeVisionUsages)|\(javaCodeVisionImplementations)"
        controller.codeVisionEnabled = areCodeVisionLensesEnabled
        controller.appliesRefactoringsInPlace = inPlaceRefactoring
        controller.confirmsInlineVariable = confirmsInlineVariable
        controller.postfixExpansionSettings = javaPostfix.expansionSettings
        controller.commandCompletionSettings = commandCompletion
        var inline = InlineCompletionSettings()
        inline.isEnabled = inlineCompletionEnabled
        inline.multiLineEnabled = inlineCompletionMultiLine
        inline.syncWithPopup = inlineCompletionSyncWithPopup
        inline.otherLanguagesEnabled = inlineCompletionOtherLanguages
        inline.acceptKey = inlineCompletionAcceptKey
        controller.inlineCompletionSettings = inline
        controller.onInlineCompletionSettingsChanged = { [weak self] settings in
            self?.inlineCompletionAcceptKey = settings.acceptKey
        }
    }

    /// Editor zoom, in percent of ``fontSize``. Lives for the session only: the size chosen in
    /// Settings stays what is saved, and Actual Size returns to it.
    var zoomPercent = 100

    static let zoomStep = 10
    static let zoomRange = 50...300

    /// The size the editor draws at: ``fontSize`` scaled by the zoom.
    var effectiveFontSize: Double {
        Self.scaledFontSize(fontSize, zoomPercent: zoomPercent)
    }

    static func scaledFontSize(_ fontSize: Double, zoomPercent: Int) -> Double {
        fontSize * Double(zoomPercent) / 100
    }

    /// The zoom after `steps` steps up (or down when negative), kept within ``zoomRange``.
    static func zoomed(_ percent: Int, bySteps steps: Int) -> Int {
        min(max(percent + steps * zoomStep, zoomRange.lowerBound), zoomRange.upperBound)
    }

    func applyTheme() {
        IDEEditorTheme.shared.rebuild(themeID: themeID, fontSize: effectiveFontSize, fontName: fontName, ligatures: fontLigatures, scaleMarkdownHeadings: scaleMarkdownHeadings)
    }

    func snapshot() -> IDEPreferencesSnapshot {
        IDEPreferencesSnapshot(
            fontSize: fontSize,
            fontName: fontName,
            fontLigatures: fontLigatures,
            uiFontName: uiFontName,
            uiFontSize: uiFontSize,
            themeID: themeID,
            caretShape: caretShape,
            caretColorHex: caretColorHex,
            caretBlinks: caretBlinks,
            caretBlinkIntervalMilliseconds: caretBlinkIntervalMilliseconds,
            smoothCaretBlinking: smoothCaretBlinking,
            smoothCaretMovement: smoothCaretMovement,
            scaleMarkdownHeadings: scaleMarkdownHeadings,
            tabWidth: tabWidth,
            useSpacesForTab: useSpacesForTab,
            wrapLines: wrapLines,
            showLineNumbers: showLineNumbers,
            isLineFoldingEnabled: isLineFoldingEnabled,
            showMinimap: showMinimap,
            isMetalRenderingEnabled: isMetalRenderingEnabled,
            keymapPreset: keymapPreset,
            showMethodSeparators: showMethodSeparators,
            highlightsOccurrencesOfSelection: highlightsOccurrencesOfSelection,
            insertPairedBrackets: insertPairedBrackets,
            insertPairedQuotes: insertPairedQuotes,
            insertClosingBraceOnEnter: insertClosingBraceOnEnter,
            insertClosingTagOnTagCompletion: insertClosingTagOnTagCompletion,
            autoCloseTagOnSlash: autoCloseTagOnSlash,
            markModifiedTabs: markModifiedTabs,
            saveOnFocusLoss: saveOnFocusLoss,
            saveWhenIdle: saveWhenIdle,
            idleSaveSeconds: idleSaveSeconds,
            reformatOnSave: reformatOnSave,
            reformatsWholeFileOnSave: reformatsWholeFileOnSave,
            codeCleanupOnSave: codeCleanupOnSave,
            keepsTrailingWhitespaceOnCaretLine: keepsTrailingWhitespaceOnCaretLine,
            ensureNewlineAtEndOfFile: ensureNewlineAtEndOfFile,
            buildProjectOnSave: buildProjectOnSave,
            stripTrailingWhitespaceOnSave: stripTrailingWhitespaceOnSave,
            showInvisibleCharacters: showInvisibleCharacters,
            showPageGuide: showPageGuide,
            pageGuideColumn: pageGuideColumn,
            lineHeightMultiplier: lineHeightMultiplier,
            isTypewriterScrollingEnabled: isTypewriterScrollingEnabled,
            isDistractionFreeModeEnabled: isDistractionFreeModeEnabled,
            isFocusModeEnabled: isFocusModeEnabled,
            isFocusModeToolbarFadeEnabled: isFocusModeToolbarFadeEnabled,
            showScrollbars: showScrollbars,
            showEditorFragmentPreview: showEditorFragmentPreview,
            flattenJavaPackages: flattenJavaPackages,
            javaPostfix: javaPostfix
        )
    }

    func restore(from snapshot: IDEPreferencesSnapshot) {
        fontSize = snapshot.fontSize
        fontName = snapshot.fontName
        fontLigatures = snapshot.fontLigatures
        uiFontName = snapshot.uiFontName
        uiFontSize = snapshot.uiFontSize
        IDEUIFonts.setCurrentFamilyName(uiFontName)
        IDEUIFonts.setCurrentFontSize(uiFontSize)
        themeID = snapshot.themeID
        caretShape = snapshot.caretShape
        caretColorHex = snapshot.caretColorHex
        caretBlinks = snapshot.caretBlinks
        caretBlinkIntervalMilliseconds = snapshot.caretBlinkIntervalMilliseconds
        smoothCaretBlinking = snapshot.smoothCaretBlinking
        smoothCaretMovement = snapshot.smoothCaretMovement
        scaleMarkdownHeadings = snapshot.scaleMarkdownHeadings
        tabWidth = snapshot.tabWidth
        useSpacesForTab = snapshot.useSpacesForTab
        wrapLines = snapshot.wrapLines
        showLineNumbers = snapshot.showLineNumbers
        isLineFoldingEnabled = snapshot.isLineFoldingEnabled
        showMinimap = snapshot.showMinimap
        isMetalRenderingEnabled = snapshot.isMetalRenderingEnabled
        keymapPreset = snapshot.keymapPreset
        showMethodSeparators = snapshot.showMethodSeparators
        highlightsOccurrencesOfSelection = snapshot.highlightsOccurrencesOfSelection
        insertPairedBrackets = snapshot.insertPairedBrackets
        insertPairedQuotes = snapshot.insertPairedQuotes
        insertClosingBraceOnEnter = snapshot.insertClosingBraceOnEnter
        insertClosingTagOnTagCompletion = snapshot.insertClosingTagOnTagCompletion
        autoCloseTagOnSlash = snapshot.autoCloseTagOnSlash
        markModifiedTabs = snapshot.markModifiedTabs
        saveOnFocusLoss = snapshot.saveOnFocusLoss
        saveWhenIdle = snapshot.saveWhenIdle
        idleSaveSeconds = snapshot.idleSaveSeconds
        reformatOnSave = snapshot.reformatOnSave
        reformatsWholeFileOnSave = snapshot.reformatsWholeFileOnSave
        codeCleanupOnSave = snapshot.codeCleanupOnSave
        keepsTrailingWhitespaceOnCaretLine = snapshot.keepsTrailingWhitespaceOnCaretLine
        ensureNewlineAtEndOfFile = snapshot.ensureNewlineAtEndOfFile
        buildProjectOnSave = snapshot.buildProjectOnSave
        stripTrailingWhitespaceOnSave = snapshot.stripTrailingWhitespaceOnSave
        showInvisibleCharacters = snapshot.showInvisibleCharacters
        showPageGuide = snapshot.showPageGuide
        pageGuideColumn = snapshot.pageGuideColumn
        lineHeightMultiplier = snapshot.lineHeightMultiplier
        isTypewriterScrollingEnabled = snapshot.isTypewriterScrollingEnabled
        isDistractionFreeModeEnabled = snapshot.isDistractionFreeModeEnabled
        isFocusModeEnabled = snapshot.isFocusModeEnabled
        isFocusModeToolbarFadeEnabled = snapshot.isFocusModeToolbarFadeEnabled
        showScrollbars = snapshot.showScrollbars
        showEditorFragmentPreview = snapshot.showEditorFragmentPreview
        flattenJavaPackages = snapshot.flattenJavaPackages
        javaPostfix = snapshot.javaPostfix
    }
}

struct IDEPreferencesSnapshot: Codable, Equatable {
    var fontSize: Double
    var fontName: String
    var fontLigatures: Bool
    var uiFontName: String
    var uiFontSize: Double
    var themeID: String
    var caretShape: CaretShape
    var caretColorHex: UInt32?
    var caretBlinks: Bool
    var caretBlinkIntervalMilliseconds: Int
    var smoothCaretBlinking: Bool
    var smoothCaretMovement: Bool
    var scaleMarkdownHeadings: Bool
    var tabWidth: Int
    var useSpacesForTab: Bool
    var wrapLines: Bool
    var showLineNumbers: Bool
    var isLineFoldingEnabled: Bool
    var showMinimap: Bool
    var isMetalRenderingEnabled: Bool
    var keymapPreset: KeymapPreset
    var showMethodSeparators: Bool
    var highlightsOccurrencesOfSelection: Bool
    var insertPairedBrackets: Bool
    var insertPairedQuotes: Bool
    var insertClosingBraceOnEnter: Bool
    var insertClosingTagOnTagCompletion: Bool
    var autoCloseTagOnSlash: Bool
    var markModifiedTabs: Bool
    var saveOnFocusLoss: Bool
    var saveWhenIdle: Bool
    var idleSaveSeconds: Int
    var reformatOnSave: Bool
    var reformatsWholeFileOnSave: Bool
    var codeCleanupOnSave: Bool
    var keepsTrailingWhitespaceOnCaretLine: Bool
    var ensureNewlineAtEndOfFile: Bool
    var buildProjectOnSave: Bool
    var stripTrailingWhitespaceOnSave: IDEStripWhitespaceScope
    var showInvisibleCharacters: Bool
    var showPageGuide: Bool
    var pageGuideColumn: Int
    var lineHeightMultiplier: Double
    var isTypewriterScrollingEnabled: Bool
    var isDistractionFreeModeEnabled: Bool
    var isFocusModeEnabled: Bool
    var isFocusModeToolbarFadeEnabled: Bool
    var showScrollbars: Bool
    var showEditorFragmentPreview: Bool
    var flattenJavaPackages: Bool
    var javaPostfix: JavaPostfixConfiguration

    init(
        fontSize: Double,
        fontName: String = IDEEditorFonts.defaultFamilyName,
        fontLigatures: Bool = false,
        uiFontName: String = IDEUIFonts.defaultFamilyName,
        uiFontSize: Double = IDEUIFonts.defaultFontSize,
        themeID: String = ThemeCatalog.defaultDarkID,
        caretShape: CaretShape = .bar,
        caretColorHex: UInt32? = nil,
        caretBlinks: Bool = true,
        caretBlinkIntervalMilliseconds: Int = 500,
        smoothCaretBlinking: Bool = true,
        smoothCaretMovement: Bool = true,
        scaleMarkdownHeadings: Bool = true,
        tabWidth: Int,
        useSpacesForTab: Bool,
        wrapLines: Bool,
        showLineNumbers: Bool,
        isLineFoldingEnabled: Bool,
        showMinimap: Bool,
        isMetalRenderingEnabled: Bool,
        keymapPreset: KeymapPreset,
        showMethodSeparators: Bool = true,
        highlightsOccurrencesOfSelection: Bool = true,
        insertPairedBrackets: Bool = true,
        insertPairedQuotes: Bool = true,
        insertClosingBraceOnEnter: Bool = true,
        insertClosingTagOnTagCompletion: Bool = true,
        autoCloseTagOnSlash: Bool = true,
        markModifiedTabs: Bool = true,
        saveOnFocusLoss: Bool = true,
        saveWhenIdle: Bool = true,
        idleSaveSeconds: Int = 15,
        reformatOnSave: Bool = false,
        reformatsWholeFileOnSave: Bool = false,
        codeCleanupOnSave: Bool = false,
        keepsTrailingWhitespaceOnCaretLine: Bool = true,
        ensureNewlineAtEndOfFile: Bool = false,
        buildProjectOnSave: Bool = false,
        stripTrailingWhitespaceOnSave: IDEStripWhitespaceScope = .modifiedLines,
        showInvisibleCharacters: Bool = false,
        showPageGuide: Bool = false,
        pageGuideColumn: Int = 120,
        lineHeightMultiplier: Double = 1.2,
        isTypewriterScrollingEnabled: Bool = false,
        isDistractionFreeModeEnabled: Bool = false,
        isFocusModeEnabled: Bool = false,
        isFocusModeToolbarFadeEnabled: Bool = false,
        showScrollbars: Bool = true,
        showEditorFragmentPreview: Bool = true,
        flattenJavaPackages: Bool = false,
        javaPostfix: JavaPostfixConfiguration = .standard
    ) {
        self.fontSize = fontSize
        self.fontName = fontName
        self.fontLigatures = fontLigatures
        self.uiFontName = uiFontName
        self.uiFontSize = uiFontSize
        self.themeID = themeID
        self.caretShape = caretShape
        self.caretColorHex = caretColorHex
        self.caretBlinks = caretBlinks
        self.caretBlinkIntervalMilliseconds = caretBlinkIntervalMilliseconds
        self.smoothCaretBlinking = smoothCaretBlinking
        self.smoothCaretMovement = smoothCaretMovement
        self.scaleMarkdownHeadings = scaleMarkdownHeadings
        self.tabWidth = tabWidth
        self.useSpacesForTab = useSpacesForTab
        self.wrapLines = wrapLines
        self.showLineNumbers = showLineNumbers
        self.isLineFoldingEnabled = isLineFoldingEnabled
        self.showMinimap = showMinimap
        self.isMetalRenderingEnabled = isMetalRenderingEnabled
        self.keymapPreset = keymapPreset
        self.showMethodSeparators = showMethodSeparators
        self.highlightsOccurrencesOfSelection = highlightsOccurrencesOfSelection
        self.insertPairedBrackets = insertPairedBrackets
        self.insertPairedQuotes = insertPairedQuotes
        self.insertClosingBraceOnEnter = insertClosingBraceOnEnter
        self.insertClosingTagOnTagCompletion = insertClosingTagOnTagCompletion
        self.autoCloseTagOnSlash = autoCloseTagOnSlash
        self.markModifiedTabs = markModifiedTabs
        self.saveOnFocusLoss = saveOnFocusLoss
        self.saveWhenIdle = saveWhenIdle
        self.idleSaveSeconds = idleSaveSeconds
        self.reformatOnSave = reformatOnSave
        self.reformatsWholeFileOnSave = reformatsWholeFileOnSave
        self.codeCleanupOnSave = codeCleanupOnSave
        self.keepsTrailingWhitespaceOnCaretLine = keepsTrailingWhitespaceOnCaretLine
        self.ensureNewlineAtEndOfFile = ensureNewlineAtEndOfFile
        self.buildProjectOnSave = buildProjectOnSave
        self.stripTrailingWhitespaceOnSave = stripTrailingWhitespaceOnSave
        self.showInvisibleCharacters = showInvisibleCharacters
        self.showPageGuide = showPageGuide
        self.pageGuideColumn = pageGuideColumn
        self.lineHeightMultiplier = lineHeightMultiplier
        self.isTypewriterScrollingEnabled = isTypewriterScrollingEnabled
        self.isDistractionFreeModeEnabled = isDistractionFreeModeEnabled
        self.isFocusModeEnabled = isFocusModeEnabled
        self.isFocusModeToolbarFadeEnabled = isFocusModeToolbarFadeEnabled
        self.showScrollbars = showScrollbars
        self.showEditorFragmentPreview = showEditorFragmentPreview
        self.flattenJavaPackages = flattenJavaPackages
        self.javaPostfix = javaPostfix
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fontSize = try container.decode(Double.self, forKey: .fontSize)
        fontName = try container.decodeIfPresent(String.self, forKey: .fontName)
            ?? IDEEditorFonts.defaultFamilyName
        fontLigatures = try container.decodeIfPresent(Bool.self, forKey: .fontLigatures) ?? false
        uiFontName = try container.decodeIfPresent(String.self, forKey: .uiFontName)
            ?? IDEUIFonts.defaultFamilyName
        uiFontSize = try container.decodeIfPresent(Double.self, forKey: .uiFontSize)
            ?? IDEUIFonts.defaultFontSize
        themeID = try container.decodeIfPresent(String.self, forKey: .themeID)
            ?? ThemeCatalog.defaultDarkID
        caretShape = try container.decodeIfPresent(CaretShape.self, forKey: .caretShape) ?? .bar
        caretColorHex = try container.decodeIfPresent(UInt32.self, forKey: .caretColorHex)
        caretBlinks = try container.decodeIfPresent(Bool.self, forKey: .caretBlinks) ?? true
        caretBlinkIntervalMilliseconds = try container.decodeIfPresent(Int.self, forKey: .caretBlinkIntervalMilliseconds) ?? 500
        smoothCaretBlinking = try container.decodeIfPresent(Bool.self, forKey: .smoothCaretBlinking) ?? true
        smoothCaretMovement = try container.decodeIfPresent(Bool.self, forKey: .smoothCaretMovement) ?? true
        scaleMarkdownHeadings = try container.decodeIfPresent(Bool.self, forKey: .scaleMarkdownHeadings) ?? true
        tabWidth = try container.decode(Int.self, forKey: .tabWidth)
        useSpacesForTab = try container.decode(Bool.self, forKey: .useSpacesForTab)
        wrapLines = try container.decode(Bool.self, forKey: .wrapLines)
        showLineNumbers = try container.decode(Bool.self, forKey: .showLineNumbers)
        isLineFoldingEnabled = try container.decode(Bool.self, forKey: .isLineFoldingEnabled)
        showMinimap = try container.decode(Bool.self, forKey: .showMinimap)
        isMetalRenderingEnabled = try container.decode(Bool.self, forKey: .isMetalRenderingEnabled)
        keymapPreset = try container.decode(KeymapPreset.self, forKey: .keymapPreset)
        showMethodSeparators = try container.decodeIfPresent(Bool.self, forKey: .showMethodSeparators) ?? true
        highlightsOccurrencesOfSelection = try container.decodeIfPresent(Bool.self, forKey: .highlightsOccurrencesOfSelection) ?? true
        insertPairedBrackets = try container.decodeIfPresent(Bool.self, forKey: .insertPairedBrackets) ?? true
        insertPairedQuotes = try container.decodeIfPresent(Bool.self, forKey: .insertPairedQuotes) ?? true
        insertClosingBraceOnEnter = try container.decodeIfPresent(Bool.self, forKey: .insertClosingBraceOnEnter) ?? true
        insertClosingTagOnTagCompletion = try container.decodeIfPresent(Bool.self, forKey: .insertClosingTagOnTagCompletion) ?? true
        autoCloseTagOnSlash = try container.decodeIfPresent(Bool.self, forKey: .autoCloseTagOnSlash) ?? true
        markModifiedTabs = try container.decodeIfPresent(Bool.self, forKey: .markModifiedTabs) ?? true
        saveOnFocusLoss = try container.decodeIfPresent(Bool.self, forKey: .saveOnFocusLoss) ?? true
        saveWhenIdle = try container.decodeIfPresent(Bool.self, forKey: .saveWhenIdle) ?? true
        idleSaveSeconds = try container.decodeIfPresent(Int.self, forKey: .idleSaveSeconds) ?? 15
        reformatOnSave = try container.decodeIfPresent(Bool.self, forKey: .reformatOnSave) ?? false
        reformatsWholeFileOnSave = try container.decodeIfPresent(Bool.self, forKey: .reformatsWholeFileOnSave) ?? false
        codeCleanupOnSave = try container.decodeIfPresent(Bool.self, forKey: .codeCleanupOnSave) ?? false
        keepsTrailingWhitespaceOnCaretLine = try container.decodeIfPresent(Bool.self, forKey: .keepsTrailingWhitespaceOnCaretLine) ?? true
        ensureNewlineAtEndOfFile = try container.decodeIfPresent(Bool.self, forKey: .ensureNewlineAtEndOfFile) ?? false
        buildProjectOnSave = try container.decodeIfPresent(Bool.self, forKey: .buildProjectOnSave) ?? false
        stripTrailingWhitespaceOnSave = try container.decodeIfPresent(IDEStripWhitespaceScope.self, forKey: .stripTrailingWhitespaceOnSave) ?? .modifiedLines
        showInvisibleCharacters = try container.decodeIfPresent(Bool.self, forKey: .showInvisibleCharacters) ?? false
        showPageGuide = try container.decodeIfPresent(Bool.self, forKey: .showPageGuide) ?? false
        pageGuideColumn = try container.decodeIfPresent(Int.self, forKey: .pageGuideColumn) ?? 120
        lineHeightMultiplier = try container.decodeIfPresent(Double.self, forKey: .lineHeightMultiplier) ?? 1.2
        isTypewriterScrollingEnabled = try container.decodeIfPresent(Bool.self, forKey: .isTypewriterScrollingEnabled) ?? false
        isDistractionFreeModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .isDistractionFreeModeEnabled) ?? false
        isFocusModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .isFocusModeEnabled) ?? false
        isFocusModeToolbarFadeEnabled = try container.decodeIfPresent(Bool.self, forKey: .isFocusModeToolbarFadeEnabled) ?? false
        showScrollbars = try container.decodeIfPresent(Bool.self, forKey: .showScrollbars) ?? true
        showEditorFragmentPreview = try container.decodeIfPresent(Bool.self, forKey: .showEditorFragmentPreview) ?? true
        flattenJavaPackages = try container.decodeIfPresent(Bool.self, forKey: .flattenJavaPackages) ?? false
        javaPostfix = try container.decodeIfPresent(JavaPostfixConfiguration.self, forKey: .javaPostfix) ?? .standard
    }
}

enum IDEEditorFonts {
    static let defaultFamilyName = "Menlo"

    /// Monospaced families, matched by Core Text's monospace trait. Creating an `NSFont` per
    /// installed family to test `isFixedPitch` took ~350 ms inside the Settings view's first body.
    static let familyNames: [String] = {
        let traits = [kCTFontSymbolicTrait: NSNumber(value: CTFontSymbolicTraits.traitMonoSpace.rawValue)]
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontTraitsAttribute: traits] as CFDictionary)
        let collection = CTFontCollectionCreateWithFontDescriptors([descriptor] as CFArray, nil)
        let matches = CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] ?? []
        let families = matches.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String }
        return Set(families).filter { !$0.hasPrefix(".") }.sorted()
    }()

    static func choices(including current: String) -> [String] {
        if familyNames.contains(current) {
            return familyNames
        }
        return [current] + familyNames
    }

    static func nsFont(familyName: String, size: CGFloat) -> NSFont {
        if let font = NSFont(name: familyName, size: size), font.isFixedPitch {
            return font
        }
        if let members = NSFontManager.shared.availableMembers(ofFontFamily: familyName),
           let postScriptName = members.first?[0] as? String,
           let font = NSFont(name: postScriptName, size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

/// Which key opens Go to File. One trigger at a time: picking a key replaces the
/// double-tap Shift trigger (double-Shift is detected outside the keymap, so it cannot
/// sit beside another binding). ⌘P and ⇧⌘O match the Sublime and IntelliJ presets;
/// ⌥⌘P is free everywhere. A key taken by something else is freed for Go to File.
enum GoToFileShortcut: String, Codable, CaseIterable, Identifiable {
    /// Sublime-style.
    case commandP
    /// IntelliJ-style.
    case commandShiftO
    case optionCommandP
    /// The historical trigger: nothing is rebound.
    case doubleShift

    var id: String { rawValue }

    var title: String {
        switch self {
        case .commandP: "⌘P"
        case .commandShiftO: "⇧⌘O"
        case .optionCommandP: "⌥⌘P"
        case .doubleShift: "Double-tap Shift"
        }
    }

    /// The editor keystroke, or `nil` for the hard-coded double-tap.
    var keyStroke: KeyStroke? {
        switch self {
        case .commandP: KeyStroke(KeyChord("p", .command))
        case .commandShiftO: KeyStroke(KeyChord("o", [.command, .shift]))
        case .optionCommandP: KeyStroke(KeyChord("p", [.command, .option]))
        case .doubleShift: nil
        }
    }

    /// Whether double-tap Shift still opens Go to File.
    var doubleShiftEnabled: Bool { keyStroke == nil }

    /// Rebinds Go to File to ``keyStroke``, freeing the key from whatever editor action
    /// held it (Parameter Info in the IntelliJ preset). No-op for ``doubleShift``.
    func apply(to map: inout Keymap) {
        guard let stroke = keyStroke else { return }
        map.unbind(stroke)
        map.bind(stroke, to: .quickOpenFile)
    }
}

enum KeymapPreset: String, Codable, CaseIterable, Identifiable {
    case sublime
    case default_
    case intelliJ

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sublime: "Sublime Text"
        case .default_: "Default"
        case .intelliJ: "IntelliJ IDEA"
        }
    }

    var keymap: Keymap {
        switch self {
        case .sublime: .sublime
        case .default_: .default_
        case .intelliJ: .intelliJ
        }
    }
}

extension JavaLineMarkerKind {
    /// The engine glyph drawn for this kind.
    var gutterIcon: GutterLineMarkerIcon {
        switch self {
        case .implementing: return .implementing
        case .overriding: return .overriding
        case .implemented: return .implemented
        case .overridden: return .overridden
        case .siblingInherited: return .siblingInherited
        case .recursiveCall: return .recursiveCall
        }
    }

    /// The label in Settings › Java › Gutter Icons.
    var preferenceTitle: String {
        switch self {
        case .implementing: return "Implementing method"
        case .overriding: return "Overriding method"
        case .implemented: return "Implemented method"
        case .overridden: return "Overridden method"
        case .siblingInherited: return "Sibling inherited method"
        case .recursiveCall: return "Recursive call"
        }
    }
}
