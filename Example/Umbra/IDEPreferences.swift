import AppKit
import Penumbra
import SwiftUI

@MainActor
final class IDEPreferences: ObservableObject {
    static let shared = IDEPreferences()

    private enum Keys {
        static let fontSize = "com.umbra.editor.fontSize"
        static let tabWidth = "com.umbra.editor.tabWidth"
        static let useSpacesForTab = "com.umbra.editor.useSpacesForTab"
        static let wrapLines = "com.umbra.editor.wrapLines"
        static let showLineNumbers = "com.umbra.editor.showLineNumbers"
        static let isLineFoldingEnabled = "com.umbra.editor.isLineFoldingEnabled"
        static let showMinimap = "com.umbra.editor.showMinimap"
        static let metalRendering = "com.umbra.editor.metalRendering"
        static let keymapPreset = "com.umbra.editor.keymapPreset"
    }

    @Published var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: Keys.fontSize); applyTheme() }
    }

    @Published var tabWidth: Int {
        didSet { UserDefaults.standard.set(tabWidth, forKey: Keys.tabWidth) }
    }

    @Published var useSpacesForTab: Bool {
        didSet { UserDefaults.standard.set(useSpacesForTab, forKey: Keys.useSpacesForTab) }
    }

    @Published var wrapLines: Bool {
        didSet { UserDefaults.standard.set(wrapLines, forKey: Keys.wrapLines) }
    }

    @Published var showLineNumbers: Bool {
        didSet { UserDefaults.standard.set(showLineNumbers, forKey: Keys.showLineNumbers) }
    }

    @Published var isLineFoldingEnabled: Bool {
        didSet { UserDefaults.standard.set(isLineFoldingEnabled, forKey: Keys.isLineFoldingEnabled) }
    }

    @Published var showMinimap: Bool {
        didSet { UserDefaults.standard.set(showMinimap, forKey: Keys.showMinimap) }
    }

    @Published var isMetalRenderingEnabled: Bool {
        didSet { UserDefaults.standard.set(isMetalRenderingEnabled, forKey: Keys.metalRendering) }
    }

    @Published var keymapPreset: KeymapPreset {
        didSet { UserDefaults.standard.set(keymapPreset.rawValue, forKey: Keys.keymapPreset) }
    }

    var keymap: Keymap { keymapPreset.keymap }

    private init() {
        let defaults = UserDefaults.standard
        fontSize = defaults.object(forKey: Keys.fontSize) as? Double ?? 13
        tabWidth = defaults.object(forKey: Keys.tabWidth) as? Int ?? 4
        useSpacesForTab = defaults.object(forKey: Keys.useSpacesForTab) as? Bool ?? true
        wrapLines = defaults.object(forKey: Keys.wrapLines) as? Bool ?? false
        showLineNumbers = defaults.object(forKey: Keys.showLineNumbers) as? Bool ?? true
        isLineFoldingEnabled = defaults.object(forKey: Keys.isLineFoldingEnabled) as? Bool ?? true
        showMinimap = defaults.object(forKey: Keys.showMinimap) as? Bool ?? true
        isMetalRenderingEnabled = defaults.object(forKey: Keys.metalRendering) as? Bool ?? true
        let presetRaw = defaults.string(forKey: Keys.keymapPreset) ?? KeymapPreset.sublime.rawValue
        keymapPreset = KeymapPreset(rawValue: presetRaw) ?? .sublime
        applyTheme()
    }

    func apply(to textView: TextView) {
        textView.showLineNumbers = showLineNumbers
        textView.isLineFoldingEnabled = isLineFoldingEnabled
        textView.isLineWrappingEnabled = wrapLines
        textView.showMinimap = showMinimap
        textView.isMetalRenderingEnabled = isMetalRenderingEnabled
        textView.keymap = keymap
        textView.theme = IDEEditorTheme.shared
        textView.refreshGutterChrome()
    }

    func applyTheme() {
        IDEEditorTheme.shared.update(fontSize: fontSize)
    }

    func snapshot() -> IDEPreferencesSnapshot {
        IDEPreferencesSnapshot(
            fontSize: fontSize,
            tabWidth: tabWidth,
            useSpacesForTab: useSpacesForTab,
            wrapLines: wrapLines,
            showLineNumbers: showLineNumbers,
            isLineFoldingEnabled: isLineFoldingEnabled,
            showMinimap: showMinimap,
            isMetalRenderingEnabled: isMetalRenderingEnabled,
            keymapPreset: keymapPreset
        )
    }

    func restore(from snapshot: IDEPreferencesSnapshot) {
        fontSize = snapshot.fontSize
        tabWidth = snapshot.tabWidth
        useSpacesForTab = snapshot.useSpacesForTab
        wrapLines = snapshot.wrapLines
        showLineNumbers = snapshot.showLineNumbers
        isLineFoldingEnabled = snapshot.isLineFoldingEnabled
        showMinimap = snapshot.showMinimap
        isMetalRenderingEnabled = snapshot.isMetalRenderingEnabled
        keymapPreset = snapshot.keymapPreset
    }
}

struct IDEPreferencesSnapshot: Codable, Equatable {
    var fontSize: Double
    var tabWidth: Int
    var useSpacesForTab: Bool
    var wrapLines: Bool
    var showLineNumbers: Bool
    var isLineFoldingEnabled: Bool
    var showMinimap: Bool
    var isMetalRenderingEnabled: Bool
    var keymapPreset: KeymapPreset
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
