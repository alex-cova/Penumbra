import AppKit
import SwiftUI

/// The menu behind a gutter run button (a `main`, a test method, a test class): Run, Debug, and
/// Modify Run Configuration when there is one to modify. The Run and Debug items show the
/// Run / Debug in Context keys, which act on the same target when the caret is inside it.
@MainActor
enum IDERunGutterMenu {
    /// - Parameter title: what runs, quoted in the items (`Foo.main()`, `testAdds()`, `FooTest`).
    static func make(
        title: String,
        keymapPreset: KeymapPreset,
        run: @escaping () -> Void,
        debug: @escaping () -> Void,
        modify: (() -> Void)? = nil
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items(title: title, keymapPreset: keymapPreset, run: run, debug: debug) {
            menu.addItem(item)
        }
        if let modify {
            menu.addItem(.separator())
            menu.addItem(IDEClosureMenuItem(title: "Modify Run Configuration…", handler: modify))
        }
        return menu
    }

    /// Run and Debug items, for menus that hold more (the gutter's right-click menu).
    static func items(
        title: String,
        keymapPreset: KeymapPreset,
        run: @escaping () -> Void,
        debug: @escaping () -> Void
    ) -> [NSMenuItem] {
        let runItem = IDEClosureMenuItem(title: "Run ‘\(title)’", handler: run)
        runItem.image = symbol("play", color: .systemGreen)
        showShortcut(IDEMenuShortcuts.shortcut(for: .runInContext, in: keymapPreset), on: runItem)
        let debugItem = IDEClosureMenuItem(title: "Debug ‘\(title)’", handler: debug)
        debugItem.image = symbol("ladybug", color: .systemGreen)
        showShortcut(IDEMenuShortcuts.shortcut(for: .debugInContext, in: keymapPreset), on: debugItem)
        return [runItem, debugItem]
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

    static func symbol(_ name: String, color: NSColor) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color]))
    }

    /// Key equivalents on a context menu item are only drawn: the main menu's Run / Debug in
    /// Context items still own the keys.
    static func showShortcut(_ shortcut: KeyboardShortcut?, on item: NSMenuItem) {
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
