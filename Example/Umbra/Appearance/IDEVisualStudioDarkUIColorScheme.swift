import Foundation

/// Visual Studio Dark from JetBrains' Rider theme pack (`VisualStudioDark.theme.json`).
enum IDEVisualStudioDarkUIColorScheme {
    private enum Palette {
        static let border: UInt32 = 0x2C2C2C
        static let panelBackground: UInt32 = 0x3B3B3B
        static let toolwindowBackground: UInt32 = 0x323232
        static let textInputBackground: UInt32 = 0x303030
        static let tabBackgroundSelected: UInt32 = 0x2C2C2C
        static let titleBackground: UInt32 = 0x383838
        static let popupBorder: UInt32 = 0x585858
        static let regularForeground: UInt32 = 0xC0C0C6
        static let mutedForeground: UInt32 = 0x9999A8
        static let selectionBackground: UInt32 = 0x354F85
        static let linkAccented: UInt32 = 0x5F94FF
        static let validationErrorForeground: UInt32 = 0xFF9794
        static let validationWarningForeground: UInt32 = 0xEDBA68
        static let actionsGreen: UInt32 = 0x669653
        static let actionsBlue: UInt32 = 0x6786C7
        static let actionsYellow: UInt32 = 0xD9B72B
    }

    static let shared = IDEUIColorScheme(
        id: "visual-studio-dark",
        name: "Visual Studio Dark",
        isDark: true,
        window: Palette.border,
        panel: Palette.panelBackground,
        panelBorder: Palette.popupBorder,
        card: Palette.titleBackground,
        workbench: Palette.border,
        sidebar: Palette.toolwindowBackground,
        editor: Palette.textInputBackground,
        tabBar: Palette.panelBackground,
        tabActive: Palette.tabBackgroundSelected,
        tabHover: Palette.toolwindowBackground,
        controlHover: Palette.toolwindowBackground,
        border: Palette.border,
        accent: Palette.linkAccented,
        run: Palette.actionsGreen,
        foreground: Palette.regularForeground,
        muted: Palette.mutedForeground,
        selectionAccent: Palette.selectionBackground,
        selectionOpacity: 0.45,
        error: Palette.validationErrorForeground,
        gitModified: Palette.actionsBlue,
        gitAdded: Palette.actionsGreen,
        gitUntracked: Palette.actionsGreen,
        gitConflict: Palette.validationWarningForeground,
        gitIgnoredOpacity: 0.55,
        sourceRoot: Palette.actionsBlue,
        testSourceRoot: Palette.actionsGreen,
        resourcesFolder: Palette.actionsYellow
    )
}
