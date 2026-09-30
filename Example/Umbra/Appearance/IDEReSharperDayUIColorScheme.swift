import Foundation

/// ReSharper Day from JetBrains' Rider theme pack (`ReSharperDay.theme.json`).
enum IDEReSharperDayUIColorScheme {
    private enum Palette {
        static let gray1: UInt32 = 0x000000
        static let gray2: UInt32 = 0x262626
        static let gray6: UInt32 = 0x727272
        static let gray7: UInt32 = 0x858585
        static let gray12: UInt32 = 0xECECEC
        static let gray13: UInt32 = 0xF7F7F7
        static let gray14: UInt32 = 0xFFFFFF
        static let blue4: UInt32 = 0x3574F0
        static let blue11: UInt32 = 0xD4E2FF
        static let green4: UInt32 = 0x208A3C
        static let green5: UInt32 = 0x369650
        static let red4: UInt32 = 0xDB3B4B
        static let yellow2: UInt32 = 0xC27D04
        static let yellow4: UInt32 = 0xFFAF0F
        static let windowsPopupBorder: UInt32 = 0xB9BDC9
        static let blackTint12: UInt32 = 0x00000012
    }

    static let shared: IDEUIColorScheme = {
        let editor = Palette.gray14
        return IDEUIColorScheme(
            id: "resharper-day",
            name: "ReSharper Day",
            isDark: false,
            window: Palette.gray12,
            panel: Palette.gray13,
            panelBorder: Palette.windowsPopupBorder,
            card: Palette.gray12,
            workbench: Palette.gray12,
            sidebar: Palette.gray13,
            editor: editor,
            tabBar: Palette.gray14,
            tabActive: Palette.gray14,
            tabHover: Palette.gray12,
            controlHover: IDEUIColorTint.composite(Palette.blackTint12, over: editor),
            border: Palette.gray12,
            accent: Palette.blue4,
            run: Palette.green4,
            foreground: Palette.gray2,
            muted: Palette.gray7,
            selectionAccent: Palette.blue11,
            selectionOpacity: 1,
            error: Palette.red4,
            gitModified: Palette.blue4,
            gitAdded: Palette.green4,
            gitUntracked: Palette.green5,
            gitConflict: Palette.yellow4,
            gitIgnoredOpacity: 0.55,
            sourceRoot: Palette.blue4,
            testSourceRoot: Palette.green4,
            resourcesFolder: Palette.yellow2
        )
    }()
}
