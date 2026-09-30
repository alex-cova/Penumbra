import Foundation

/// A light companion to the default Umbra shell.
enum IDEUmbraLightUIColorScheme {
    static let shared = IDEUIColorScheme(
        id: "umbra-light",
        name: "Umbra Light",
        isDark: false,
        window: 0xE8E8EC,
        panel: 0xFFFFFF,
        panelBorder: 0xD4D4D8,
        card: 0xECECF0,
        workbench: 0xE8E8EC,
        sidebar: 0xF5F5F7,
        editor: 0xFFFFFF,
        tabBar: 0xF5F5F7,
        tabActive: 0xFFFFFF,
        tabHover: 0xECECF0,
        controlHover: 0xEFEFEF,
        border: 0xD4D4D8,
        accent: 0x3B82F6,
        run: 0x22C55E,
        foreground: 0x18181B,
        muted: 0x71717A,
        selectionAccent: 0x3B82F6,
        selectionOpacity: 0.15,
        error: 0xDC2626,
        gitModified: 0xCA8A04,
        gitAdded: 0x16A34A,
        gitUntracked: 0x16A34A,
        gitConflict: 0xDC2626,
        gitIgnoredOpacity: 0.55,
        sourceRoot: 0x3B82F6,
        testSourceRoot: 0x16A34A,
        resourcesFolder: 0xD97706
    )
}
