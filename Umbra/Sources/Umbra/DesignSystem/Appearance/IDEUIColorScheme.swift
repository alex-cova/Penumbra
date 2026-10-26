import SwiftUI

/// Shell colors for Umbra's chrome: sidebars, tabs, panels, status bar, and the gaps between them.
/// Editor syntax themes stay separate in Penumbra's ``ThemeCatalog``.
struct IDEUIColorScheme: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let isDark: Bool

    let window: UInt32
    let panel: UInt32
    let panelBorder: UInt32
    let card: UInt32
    let workbench: UInt32
    let sidebar: UInt32
    let editor: UInt32
    let tabBar: UInt32
    let tabActive: UInt32
    let tabHover: UInt32
    let controlHover: UInt32
    let border: UInt32
    let accent: UInt32
    let run: UInt32
    let foreground: UInt32
    let muted: UInt32
    let selectionAccent: UInt32
    let selectionOpacity: Double
    let error: UInt32
    let gitModified: UInt32
    let gitAdded: UInt32
    let gitUntracked: UInt32
    let gitConflict: UInt32
    let gitIgnoredOpacity: Double
    let sourceRoot: UInt32
    let testSourceRoot: UInt32
    let resourcesFolder: UInt32
}

enum IDEUIColorSchemeCatalog {
    static let defaultID = IDEUmbraUIColorScheme.shared.id

    static let all: [IDEUIColorScheme] = [
        IDEUmbraUIColorScheme.shared,
        IDEVisualStudioDarkUIColorScheme.shared,
        IDEUmbraLightUIColorScheme.shared,
        IDEReSharperDayUIColorScheme.shared
    ]

    static func scheme(id: String) -> IDEUIColorScheme {
        all.first { $0.id == id } ?? IDEUmbraUIColorScheme.shared
    }

    static func schemes(preferringDark: Bool) -> [IDEUIColorScheme] {
        all.filter { $0.isDark == preferringDark } + all.filter { $0.isDark != preferringDark }
    }
}
