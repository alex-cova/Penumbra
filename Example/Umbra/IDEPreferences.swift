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
        static let uiFontName = "com.umbra.editor.uiFontName"
        static let uiFontSize = "com.umbra.editor.uiFontSize"
        static let welcomeBackground = "com.umbra.editor.welcomeBackground"
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
        static let flattenJavaPackages = "com.umbra.editor.flattenJavaPackages"
        static let explorerAutoReveal = "com.umbra.editor.explorerAutoReveal"
        static let explorerSortOrder = "com.umbra.editor.explorerSortOrder"
        static let explorerFoldersOnTop = "com.umbra.editor.explorerFoldersOnTop"
        static let explorerCompactMiddlePackages = "com.umbra.editor.explorerCompactMiddlePackages"
        static let explorerShowExcludedFiles = "com.umbra.editor.explorerShowExcludedFiles"
        static let metalRendering = "com.umbra.editor.metalRendering"
        static let keymapPreset = "com.umbra.editor.keymapPreset"
        static let openFoldersIn = "com.umbra.editor.openFoldersIn"
        static let showMethodSeparators = "com.umbra.editor.showMethodSeparators"
        static let highlightsOccurrencesOfSelection = "com.umbra.editor.highlightsOccurrencesOfSelection"
        static let showInvisibleCharacters = "com.umbra.editor.showInvisibleCharacters"
        static let showPageGuide = "com.umbra.editor.showPageGuide"
        static let pageGuideColumn = "com.umbra.editor.pageGuideColumn"
        static let lineHeightMultiplier = "com.umbra.editor.lineHeightMultiplier"
        static let isTypewriterScrollingEnabled = "com.umbra.editor.isTypewriterScrollingEnabled"
        static let isDistractionFreeModeEnabled = "com.umbra.editor.isDistractionFreeModeEnabled"
        static let isFocusModeEnabled = "com.umbra.editor.isFocusModeEnabled"
        static let hasCompletedFirstRunGuide = "com.umbra.editor.hasCompletedFirstRunGuide"
        static let javaGradleAutoSync = "com.umbra.editor.javaGradleAutoSync"
        static let javaCompilerDiagnostics = "com.umbra.editor.javaCompilerDiagnostics"
        static let semanticHighlighting = "com.umbra.editor.semanticHighlighting"
        static let javaInlayHints = "com.umbra.editor.javaInlayHints"
        static let javaInlayVariableTypes = "com.umbra.editor.javaInlayVariableTypes"
        static let javaInlayLambdaTypes = "com.umbra.editor.javaInlayLambdaTypes"
        static let inlayHintsUseEditorFont = "com.umbra.editor.inlayHintsUseEditorFont"
        static let javaDisabledGutterIcons = "com.umbra.editor.javaDisabledGutterIcons"
        static let javaDisabledInspections = "com.umbra.editor.javaDisabledInspections"
        static let javaInspectionSeverities = "com.umbra.editor.javaInspectionSeverities"
        static let javaInspectionLimits = "com.umbra.editor.javaInspectionLimits"
        static let javaTreatsPublicApiAsUsed = "com.umbra.editor.javaTreatsPublicApiAsUsed"
        static let javaOptimizeImportsOnSave = "com.umbra.editor.javaOptimizeImportsOnSave"
        static let javaGradleSyncTimeoutSeconds = "com.umbra.editor.javaGradleSyncTimeoutSeconds"
        static let javaDecompilerAgreementAccepted = "com.umbra.editor.javaDecompilerAgreementAccepted"
        static let showsErrorStripe = "com.umbra.editor.showsErrorStripe"
        static let errorStripeMarkMinHeight = "com.umbra.editor.errorStripeMarkMinHeight"
        static let highlightsCurrentScope = "com.umbra.editor.highlightsCurrentScope"
        static let showStickyLines = "com.umbra.editor.showStickyLines"
        static let maximumStickyLines = "com.umbra.editor.maximumStickyLines"
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

    /// Explorer shows each Java source root's packages as flat dotted rows (IntelliJ's
    /// "Flatten Packages") instead of nested folders.
    var flattenJavaPackages: Bool {
        didSet { UserDefaults.standard.set(flattenJavaPackages, forKey: Keys.flattenJavaPackages) }
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

    /// Pins the headers of the blocks around the first visible line (class, method, `if`, loop) to
    /// the top of the editor while their bodies scroll by. Kept on this Mac, like the other code insight settings.
    var showStickyLines: Bool {
        didSet { UserDefaults.standard.set(showStickyLines, forKey: Keys.showStickyLines) }
    }

    /// The most lines sticky lines pin at once (1...10).
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

    var keymap: Keymap { keymapPreset.keymap }

    var hasCompletedFirstRunGuide: Bool {
        didSet { UserDefaults.standard.set(hasCompletedFirstRunGuide, forKey: Keys.hasCompletedFirstRunGuide) }
    }

    /// When a Gradle project opens, resolve modules and dependencies automatically. Still gated by
    /// the trust prompt. Machine-local: not part of `IDEPreferencesSnapshot`.
    var javaGradleAutoSync: Bool {
        didSet { UserDefaults.standard.set(javaGradleAutoSync, forKey: Keys.javaGradleAutoSync) }
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

    /// Whether any kind of inlay hint is on, which is when the editor asks for hints at all.
    var areInlayHintsEnabled: Bool {
        javaInlayHints || javaInlayVariableTypes || javaInlayLambdaTypes
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

    /// Codes of the Java inspections the user turned off (every rule is on by default). Stored by
    /// code so a renamed enum case cannot lose a choice. Machine-local: not part of `IDEPreferencesSnapshot`.
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

    /// How long one Gradle project-model sync may run before it is killed. A first sync may
    /// download a Gradle distribution, so this sits above `GradleCommandRunner`'s 120s default.
    var javaGradleSyncTimeoutSeconds: Int {
        didSet { UserDefaults.standard.set(javaGradleSyncTimeoutSeconds, forKey: Keys.javaGradleSyncTimeoutSeconds) }
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
        uiFontName = defaults.string(forKey: Keys.uiFontName) ?? IDEUIFonts.defaultFamilyName
        uiFontSize = defaults.object(forKey: Keys.uiFontSize) as? Double ?? IDEUIFonts.defaultFontSize
        welcomeBackground = defaults.string(forKey: Keys.welcomeBackground)
            .flatMap(IDEWelcomeBackground.init(rawValue:)) ?? .starfield
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
        flattenJavaPackages = defaults.object(forKey: Keys.flattenJavaPackages) as? Bool ?? false
        explorerAutoReveal = defaults.object(forKey: Keys.explorerAutoReveal) as? Bool ?? true
        explorerSortOrder = defaults.string(forKey: Keys.explorerSortOrder).flatMap(IDEExplorerSortOrder.init(rawValue:)) ?? .name
        explorerFoldersOnTop = defaults.object(forKey: Keys.explorerFoldersOnTop) as? Bool ?? true
        explorerCompactMiddlePackages = defaults.object(forKey: Keys.explorerCompactMiddlePackages) as? Bool ?? true
        explorerShowExcludedFiles = defaults.object(forKey: Keys.explorerShowExcludedFiles) as? Bool ?? true
        isMetalRenderingEnabled = defaults.object(forKey: Keys.metalRendering) as? Bool ?? true
        let presetRaw = defaults.string(forKey: Keys.keymapPreset) ?? KeymapPreset.sublime.rawValue
        keymapPreset = KeymapPreset(rawValue: presetRaw) ?? .sublime
        openFoldersIn = defaults.string(forKey: Keys.openFoldersIn).flatMap(IDEOpenFoldersIn.init(rawValue:)) ?? .ask
        showMethodSeparators = defaults.object(forKey: Keys.showMethodSeparators) as? Bool ?? true
        highlightsOccurrencesOfSelection = defaults.object(forKey: Keys.highlightsOccurrencesOfSelection) as? Bool ?? true
        showInvisibleCharacters = defaults.object(forKey: Keys.showInvisibleCharacters) as? Bool ?? false
        showsErrorStripe = defaults.object(forKey: Keys.showsErrorStripe) as? Bool ?? true
        errorStripeMarkMinHeight = defaults.object(forKey: Keys.errorStripeMarkMinHeight) as? Int ?? 2
        highlightsCurrentScope = defaults.object(forKey: Keys.highlightsCurrentScope) as? Bool ?? true
        showStickyLines = defaults.object(forKey: Keys.showStickyLines) as? Bool ?? true
        maximumStickyLines = min(max(defaults.object(forKey: Keys.maximumStickyLines) as? Int ?? 5, 1), 10)
        stickyLinesDisabledLanguages = defaults.stringArray(forKey: Keys.stickyLinesDisabledLanguages) ?? []
        showsDocumentationOnHover = defaults.object(forKey: Keys.showsDocumentationOnHover) as? Bool ?? true
        let storedTooltipDelay = defaults.object(forKey: Keys.tooltipDelayMilliseconds) as? Int ?? 500
        tooltipDelayMilliseconds = storedTooltipDelay
        defaults.set(storedTooltipDelay, forKey: Keys.nativeTooltipDelay)
        autoreparseDelayMilliseconds = defaults.object(forKey: Keys.autoreparseDelayMilliseconds) as? Int ?? 200
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
        hasCompletedFirstRunGuide = defaults.bool(forKey: Keys.hasCompletedFirstRunGuide)
        javaGradleAutoSync = defaults.object(forKey: Keys.javaGradleAutoSync) as? Bool ?? true
        javaCompilerDiagnostics = defaults.object(forKey: Keys.javaCompilerDiagnostics) as? Bool ?? true
        semanticHighlighting = defaults.object(forKey: Keys.semanticHighlighting) as? Bool ?? true
        javaInlayHints = defaults.bool(forKey: Keys.javaInlayHints)
        javaInlayVariableTypes = defaults.bool(forKey: Keys.javaInlayVariableTypes)
        javaInlayLambdaTypes = defaults.bool(forKey: Keys.javaInlayLambdaTypes)
        inlayHintsUseEditorFont = defaults.bool(forKey: Keys.inlayHintsUseEditorFont)
        javaDisabledGutterIcons = Set((defaults.stringArray(forKey: Keys.javaDisabledGutterIcons) ?? []).compactMap(JavaLineMarkerKind.init(rawValue:)))
        javaDisabledInspections = Set(defaults.stringArray(forKey: Keys.javaDisabledInspections) ?? Array(Self.defaultDisabledInspections))
        javaInspectionSeverities = defaults.dictionary(forKey: Keys.javaInspectionSeverities) as? [String: String] ?? [:]
        javaInspectionLimits = defaults.dictionary(forKey: Keys.javaInspectionLimits) as? [String: Int] ?? [:]
        javaTreatsPublicApiAsUsed = defaults.object(forKey: Keys.javaTreatsPublicApiAsUsed) as? Bool ?? true
        javaOptimizeImportsOnSave = defaults.bool(forKey: Keys.javaOptimizeImportsOnSave)
        javaGradleSyncTimeoutSeconds = defaults.object(forKey: Keys.javaGradleSyncTimeoutSeconds) as? Int ?? 300
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
        textView.isMetalRenderingEnabled = isMetalRenderingEnabled
        textView.showMethodSeparators = showMethodSeparators
        textView.highlightsOccurrencesOfSelection = highlightsOccurrencesOfSelection
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
        textView.keymap = keymap
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
        controller.appliesRefactoringsInPlace = inPlaceRefactoring
        controller.confirmsInlineVariable = confirmsInlineVariable
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
        IDEEditorTheme.shared.rebuild(themeID: themeID, fontSize: effectiveFontSize, fontName: fontName, scaleMarkdownHeadings: scaleMarkdownHeadings)
    }

    func snapshot() -> IDEPreferencesSnapshot {
        IDEPreferencesSnapshot(
            fontSize: fontSize,
            fontName: fontName,
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
            showInvisibleCharacters: showInvisibleCharacters,
            showPageGuide: showPageGuide,
            pageGuideColumn: pageGuideColumn,
            lineHeightMultiplier: lineHeightMultiplier,
            isTypewriterScrollingEnabled: isTypewriterScrollingEnabled,
            isDistractionFreeModeEnabled: isDistractionFreeModeEnabled,
            isFocusModeEnabled: isFocusModeEnabled,
            showScrollbars: showScrollbars,
            flattenJavaPackages: flattenJavaPackages
        )
    }

    func restore(from snapshot: IDEPreferencesSnapshot) {
        fontSize = snapshot.fontSize
        fontName = snapshot.fontName
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
        showInvisibleCharacters = snapshot.showInvisibleCharacters
        showPageGuide = snapshot.showPageGuide
        pageGuideColumn = snapshot.pageGuideColumn
        lineHeightMultiplier = snapshot.lineHeightMultiplier
        isTypewriterScrollingEnabled = snapshot.isTypewriterScrollingEnabled
        isDistractionFreeModeEnabled = snapshot.isDistractionFreeModeEnabled
        isFocusModeEnabled = snapshot.isFocusModeEnabled
        showScrollbars = snapshot.showScrollbars
        flattenJavaPackages = snapshot.flattenJavaPackages
    }
}

struct IDEPreferencesSnapshot: Codable, Equatable {
    var fontSize: Double
    var fontName: String
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
    var showInvisibleCharacters: Bool
    var showPageGuide: Bool
    var pageGuideColumn: Int
    var lineHeightMultiplier: Double
    var isTypewriterScrollingEnabled: Bool
    var isDistractionFreeModeEnabled: Bool
    var isFocusModeEnabled: Bool
    var showScrollbars: Bool
    var flattenJavaPackages: Bool

    init(
        fontSize: Double,
        fontName: String = IDEEditorFonts.defaultFamilyName,
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
        showInvisibleCharacters: Bool = false,
        showPageGuide: Bool = false,
        pageGuideColumn: Int = 120,
        lineHeightMultiplier: Double = 1.2,
        isTypewriterScrollingEnabled: Bool = false,
        isDistractionFreeModeEnabled: Bool = false,
        isFocusModeEnabled: Bool = false,
        showScrollbars: Bool = true,
        flattenJavaPackages: Bool = false
    ) {
        self.fontSize = fontSize
        self.fontName = fontName
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
        self.showInvisibleCharacters = showInvisibleCharacters
        self.showPageGuide = showPageGuide
        self.pageGuideColumn = pageGuideColumn
        self.lineHeightMultiplier = lineHeightMultiplier
        self.isTypewriterScrollingEnabled = isTypewriterScrollingEnabled
        self.isDistractionFreeModeEnabled = isDistractionFreeModeEnabled
        self.isFocusModeEnabled = isFocusModeEnabled
        self.showScrollbars = showScrollbars
        self.flattenJavaPackages = flattenJavaPackages
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fontSize = try container.decode(Double.self, forKey: .fontSize)
        fontName = try container.decodeIfPresent(String.self, forKey: .fontName)
            ?? IDEEditorFonts.defaultFamilyName
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
        showInvisibleCharacters = try container.decodeIfPresent(Bool.self, forKey: .showInvisibleCharacters) ?? false
        showPageGuide = try container.decodeIfPresent(Bool.self, forKey: .showPageGuide) ?? false
        pageGuideColumn = try container.decodeIfPresent(Int.self, forKey: .pageGuideColumn) ?? 120
        lineHeightMultiplier = try container.decodeIfPresent(Double.self, forKey: .lineHeightMultiplier) ?? 1.2
        isTypewriterScrollingEnabled = try container.decodeIfPresent(Bool.self, forKey: .isTypewriterScrollingEnabled) ?? false
        isDistractionFreeModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .isDistractionFreeModeEnabled) ?? false
        isFocusModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .isFocusModeEnabled) ?? false
        showScrollbars = try container.decodeIfPresent(Bool.self, forKey: .showScrollbars) ?? true
        flattenJavaPackages = try container.decodeIfPresent(Bool.self, forKey: .flattenJavaPackages) ?? false
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
