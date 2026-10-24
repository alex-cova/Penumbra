import Foundation

/// Default Umbra shell, ported from a JetBrains Fleet `.colors.json` UI export.
enum IDEUmbraUIColorScheme {
    private enum Palette {
        static let neutral10: UInt32 = 0x090909
        static let neutral20: UInt32 = 0x18191B
        static let neutral30: UInt32 = 0x252629
        static let neutral110: UInt32 = 0x898E94
        static let neutral140: UInt32 = 0xE0E1E4
        static let blue100: UInt32 = 0x2A7DEB
        static let blue110: UInt32 = 0x4B8DEC
        static let blue120: UInt32 = 0x71A3EF
        static let green100: UInt32 = 0x169068
        static let green110: UInt32 = 0x409D78
        static let green120: UInt32 = 0x69B090
        static let red110: UInt32 = 0xEC5D6F
        static let yellow110: UInt32 = 0xBD8128
        static let yellow120: UInt32 = 0xCD984D
        static let lightTint4: UInt32 = 0xFFFFFF0B
        static let lightTint7: UInt32 = 0xFFFFFF12
        static let lightTint13: UInt32 = 0xFFFFFF21
    }

    static let shared: IDEUIColorScheme = {
        let surface = Palette.neutral20
        let shell = Palette.neutral10
        return IDEUIColorScheme(
            id: "umbra",
            name: "Umbra",
            isDark: true,
            window: shell,
            panel: surface,
            panelBorder: IDEUIColorTint.composite(Palette.lightTint13, over: surface),
            card: Palette.neutral30,
            workbench: shell,
            sidebar: surface,
            editor: surface,
            tabBar: surface,
            tabActive: IDEUIColorTint.composite(Palette.lightTint7, over: surface),
            tabHover: IDEUIColorTint.composite(Palette.lightTint4, over: surface),
            controlHover: IDEUIColorTint.composite(Palette.lightTint4, over: surface),
            border: IDEUIColorTint.composite(Palette.lightTint13, over: surface),
            accent: Palette.blue100,
            run: Palette.green100,
            foreground: Palette.neutral140,
            muted: Palette.neutral110,
            selectionAccent: Palette.blue100,
            selectionOpacity: 0.40,
            error: Palette.red110,
            gitModified: Palette.blue120,
            gitAdded: Palette.green120,
            gitUntracked: Palette.green120,
            gitConflict: Palette.yellow120,
            gitIgnoredOpacity: 0.55,
            sourceRoot: Palette.blue110,
            testSourceRoot: Palette.green110,
            resourcesFolder: Palette.yellow110
        )
    }()
}
