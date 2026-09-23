import AppKit
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
        static let themeID = "com.umbra.editor.themeID"
        static let scaleMarkdownHeadings = "com.umbra.editor.scaleMarkdownHeadings"
        static let tabWidth = "com.umbra.editor.tabWidth"
        static let useSpacesForTab = "com.umbra.editor.useSpacesForTab"
        static let wrapLines = "com.umbra.editor.wrapLines"
        static let showLineNumbers = "com.umbra.editor.showLineNumbers"
        static let isLineFoldingEnabled = "com.umbra.editor.isLineFoldingEnabled"
        static let showMinimap = "com.umbra.editor.showMinimap"
        static let showScrollbars = "com.umbra.editor.showScrollbars"
        static let flattenJavaPackages = "com.umbra.editor.flattenJavaPackages"
        static let metalRendering = "com.umbra.editor.metalRendering"
        static let keymapPreset = "com.umbra.editor.keymapPreset"
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
        static let javaGradleSyncTimeoutSeconds = "com.umbra.editor.javaGradleSyncTimeoutSeconds"
        static let javaDecompilerAgreementAccepted = "com.umbra.editor.javaDecompilerAgreementAccepted"
    }

    var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: Keys.fontSize); applyTheme() }
    }

    var fontName: String {
        didSet { UserDefaults.standard.set(fontName, forKey: Keys.fontName); applyTheme() }
    }

    var themeID: String {
        didSet { UserDefaults.standard.set(themeID, forKey: Keys.themeID); applyTheme() }
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

    var isMetalRenderingEnabled: Bool {
        didSet { UserDefaults.standard.set(isMetalRenderingEnabled, forKey: Keys.metalRendering) }
    }

    var keymapPreset: KeymapPreset {
        didSet { UserDefaults.standard.set(keymapPreset.rawValue, forKey: Keys.keymapPreset) }
    }

    var showMethodSeparators: Bool {
        didSet { UserDefaults.standard.set(showMethodSeparators, forKey: Keys.showMethodSeparators) }
    }

    var highlightsOccurrencesOfSelection: Bool {
        didSet {
            UserDefaults.standard.set(highlightsOccurrencesOfSelection, forKey: Keys.highlightsOccurrencesOfSelection)
        }
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

    private init() {
        let defaults = UserDefaults.standard
        fontSize = defaults.object(forKey: Keys.fontSize) as? Double ?? 13
        fontName = defaults.string(forKey: Keys.fontName) ?? IDEEditorFonts.defaultFamilyName
        themeID = defaults.string(forKey: Keys.themeID) ?? ThemeCatalog.defaultDarkID
        scaleMarkdownHeadings = defaults.object(forKey: Keys.scaleMarkdownHeadings) as? Bool ?? true
        tabWidth = defaults.object(forKey: Keys.tabWidth) as? Int ?? 4
        useSpacesForTab = defaults.object(forKey: Keys.useSpacesForTab) as? Bool ?? true
        wrapLines = defaults.object(forKey: Keys.wrapLines) as? Bool ?? false
        showLineNumbers = defaults.object(forKey: Keys.showLineNumbers) as? Bool ?? true
        isLineFoldingEnabled = defaults.object(forKey: Keys.isLineFoldingEnabled) as? Bool ?? true
        showMinimap = defaults.object(forKey: Keys.showMinimap) as? Bool ?? true
        showScrollbars = defaults.object(forKey: Keys.showScrollbars) as? Bool ?? true
        flattenJavaPackages = defaults.object(forKey: Keys.flattenJavaPackages) as? Bool ?? false
        isMetalRenderingEnabled = defaults.object(forKey: Keys.metalRendering) as? Bool ?? true
        let presetRaw = defaults.string(forKey: Keys.keymapPreset) ?? KeymapPreset.sublime.rawValue
        keymapPreset = KeymapPreset(rawValue: presetRaw) ?? .sublime
        showMethodSeparators = defaults.object(forKey: Keys.showMethodSeparators) as? Bool ?? true
        highlightsOccurrencesOfSelection = defaults.object(forKey: Keys.highlightsOccurrencesOfSelection) as? Bool ?? true
        showInvisibleCharacters = defaults.object(forKey: Keys.showInvisibleCharacters) as? Bool ?? false
        showPageGuide = defaults.object(forKey: Keys.showPageGuide) as? Bool ?? false
        pageGuideColumn = defaults.object(forKey: Keys.pageGuideColumn) as? Int ?? 120
        lineHeightMultiplier = defaults.object(forKey: Keys.lineHeightMultiplier) as? Double ?? 1
        isTypewriterScrollingEnabled = defaults.object(forKey: Keys.isTypewriterScrollingEnabled) as? Bool ?? false
        isDistractionFreeModeEnabled = defaults.object(forKey: Keys.isDistractionFreeModeEnabled) as? Bool ?? false
        isFocusModeEnabled = defaults.object(forKey: Keys.isFocusModeEnabled) as? Bool ?? false
        hasCompletedFirstRunGuide = defaults.bool(forKey: Keys.hasCompletedFirstRunGuide)
        javaGradleAutoSync = defaults.object(forKey: Keys.javaGradleAutoSync) as? Bool ?? true
        javaGradleSyncTimeoutSeconds = defaults.object(forKey: Keys.javaGradleSyncTimeoutSeconds) as? Int ?? 300
        javaDecompilerAgreementAccepted = defaults.bool(forKey: Keys.javaDecompilerAgreementAccepted)
        applyTheme()
    }

    func apply(to textView: TextView) {
        textView.indentStrategy = useSpacesForTab ? .space(length: tabWidth) : .tab(length: tabWidth)
        textView.showLineNumbers = showLineNumbers
        textView.isLineFoldingEnabled = isLineFoldingEnabled
        textView.isLineWrappingEnabled = wrapLines
        textView.showMinimap = showMinimap
        textView.showsScrollers = showScrollbars
        textView.isMetalRenderingEnabled = isMetalRenderingEnabled
        textView.showMethodSeparators = showMethodSeparators
        textView.highlightsOccurrencesOfSelection = highlightsOccurrencesOfSelection
        textView.showTabs = showInvisibleCharacters
        textView.showSpaces = showInvisibleCharacters
        textView.showPageGuide = showPageGuide
        textView.pageGuideColumn = pageGuideColumn
        textView.lineHeightMultiplier = CGFloat(lineHeightMultiplier)
        textView.isTypewriterScrollingEnabled = isTypewriterScrollingEnabled
        if isTypewriterScrollingEnabled {
            textView.isAutomaticScrollEnabled = true
        }
        textView.isDistractionFreeModeEnabled = isDistractionFreeModeEnabled
        textView.isFocusModeEnabled = isFocusModeEnabled
        textView.keymap = keymap
        textView.theme = IDEEditorTheme.shared.current
        textView.redisplayVisibleLines()
        textView.refreshGutterChrome()
    }

    func applyTheme() {
        IDEEditorTheme.shared.rebuild(themeID: themeID, fontSize: fontSize, fontName: fontName, scaleMarkdownHeadings: scaleMarkdownHeadings)
    }

    func snapshot() -> IDEPreferencesSnapshot {
        IDEPreferencesSnapshot(
            fontSize: fontSize,
            fontName: fontName,
            themeID: themeID,
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
        themeID = snapshot.themeID
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
    var themeID: String
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
        themeID: String = ThemeCatalog.defaultDarkID,
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
        lineHeightMultiplier: Double = 1,
        isTypewriterScrollingEnabled: Bool = false,
        isDistractionFreeModeEnabled: Bool = false,
        isFocusModeEnabled: Bool = false,
        showScrollbars: Bool = true,
        flattenJavaPackages: Bool = false
    ) {
        self.fontSize = fontSize
        self.fontName = fontName
        self.themeID = themeID
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
        themeID = try container.decodeIfPresent(String.self, forKey: .themeID)
            ?? ThemeCatalog.defaultDarkID
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
        lineHeightMultiplier = try container.decodeIfPresent(Double.self, forKey: .lineHeightMultiplier) ?? 1
        isTypewriterScrollingEnabled = try container.decodeIfPresent(Bool.self, forKey: .isTypewriterScrollingEnabled) ?? false
        isDistractionFreeModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .isDistractionFreeModeEnabled) ?? false
        isFocusModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .isFocusModeEnabled) ?? false
        showScrollbars = try container.decodeIfPresent(Bool.self, forKey: .showScrollbars) ?? true
        flattenJavaPackages = try container.decodeIfPresent(Bool.self, forKey: .flattenJavaPackages) ?? false
    }
}

enum IDEEditorFonts {
    static let defaultFamilyName = "Menlo"

    static let familyNames: [String] = {
        let manager = NSFontManager.shared
        return manager.availableFontFamilies
            .filter { family in
                guard let members = manager.availableMembers(ofFontFamily: family),
                      let postScriptName = members.first?[0] as? String,
                      let font = NSFont(name: postScriptName, size: 12) else {
                    return false
                }
                return font.isFixedPitch
            }
            .sorted()
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
