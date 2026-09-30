import AppKit
import SwiftUI

/// The menu behind the gutter's play button on a Java `main`: Run, Debug, and Modify Run
/// Configuration. The Run and Debug items show the Run / Debug in Context keys, which act on the
/// same `main` when the caret is inside it.
@MainActor
enum IDEMainRunMenu {
    static func make(
        methodName: String,
        keymapPreset: KeymapPreset,
        run: @escaping () -> Void,
        debug: @escaping () -> Void,
        modify: @escaping () -> Void
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let runItem = IDEClosureMenuItem(title: "Run ‘\(methodName)’", handler: run)
        runItem.image = symbol("play")
        showShortcut(IDEMenuShortcuts.shortcut(for: .runInContext, in: keymapPreset), on: runItem)
        menu.addItem(runItem)
        let debugItem = IDEClosureMenuItem(title: "Debug ‘\(methodName)’", handler: debug)
        debugItem.image = symbol("ladybug")
        showShortcut(IDEMenuShortcuts.shortcut(for: .debugInContext, in: keymapPreset), on: debugItem)
        menu.addItem(debugItem)
        menu.addItem(.separator())
        menu.addItem(IDEClosureMenuItem(title: "Modify Run Configuration…", handler: modify))
        return menu
    }

    /// Opens `menu` at the click that is being handled, since the gutter reports clicks from
    /// inside `mouseDown`; at the pointer otherwise.
    static func popUp(_ menu: NSMenu, in view: NSView) {
        if let event = NSApp.currentEvent, event.type == .leftMouseDown, event.window === view.window {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
            return
        }
        guard let window = view.window else { return }
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        menu.popUp(positioning: nil, at: point, in: view)
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemGreen]))
    }

    /// Key equivalents on a context menu item are only drawn: the main menu's Run / Debug in
    /// Context items still own the keys.
    private static func showShortcut(_ shortcut: KeyboardShortcut?, on item: NSMenuItem) {
        guard let shortcut else { return }
        item.keyEquivalent = String(shortcut.key.character).lowercased()
        var flags: NSEvent.ModifierFlags = []
        if shortcut.modifiers.contains(.command) { flags.insert(.command) }
        if shortcut.modifiers.contains(.shift) { flags.insert(.shift) }
        if shortcut.modifiers.contains(.option) { flags.insert(.option) }
        if shortcut.modifiers.contains(.control) { flags.insert(.control) }
        item.keyEquivalentModifierMask = flags
    }
}
