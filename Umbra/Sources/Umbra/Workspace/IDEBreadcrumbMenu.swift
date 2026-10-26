import AppKit
import EditorIntelligence
import Penumbra
import SwiftUI

/// The dropdowns the status bar breadcrumb opens: a folder or file segment lists that folder
/// (subfolders open lazily as submenus, so a click never walks more than one directory level),
/// a package segment lists the classes and compacted subpackages inside it, and a symbol
/// segment lists the enclosing type and its members.
@MainActor
enum IDEBreadcrumbMenu {
    /// The entries of `directory`, with `currentURL` checked. `onReveal` adds a trailing
    /// "Reveal in Explorer" item for the segment itself.
    static func directoryMenu(
        _ directory: URL,
        current currentURL: URL?,
        onOpen: @escaping (URL) -> Void,
        onReveal: (() -> Void)?
    ) -> NSMenu {
        let menu = IDEDirectoryMenu(directory: directory, currentPath: currentURL?.standardizedFileURL.path, onOpen: onOpen)
        menu.populate()
        if let onReveal {
            menu.addItem(.separator())
            let reveal = IDEClosureMenuItem(title: "Reveal in Explorer", handler: onReveal)
            reveal.image = image(systemName: "sidebar.left", tint: .secondaryLabelColor)
            menu.addItem(reveal)
        }
        return menu
    }

    /// Classes and compacted subpackages inside `directory`. Subpackages open as further package
    /// menus. `node` is that directory in the project tree; without it the menu lists one disk
    /// level and does not collapse single-child chains.
    static func packageMenu(
        _ directory: URL,
        current currentURL: URL?,
        node: IDEFileNode?,
        onOpen: @escaping (URL) -> Void,
        onReveal: @escaping (URL) -> Void
    ) -> NSMenu {
        let menu = IDEPackageMenu(
            directory: directory,
            node: node,
            currentPath: currentURL?.standardizedFileURL.path,
            onOpen: onOpen,
            onReveal: onReveal
        )
        menu.populate()
        return menu
    }

    /// `container` and everything it declares, nested types indented under their parent, with
    /// `selectedID` checked.
    static func structureMenu(
        _ container: StructureNode,
        selectedID: String,
        onSelect: @escaping (StructureNode) -> Void
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ node: StructureNode, depth: Int) {
            let item = IDEClosureMenuItem(title: node.title) { onSelect(node) }
            item.image = image(systemName: node.kind.iconSystemName, tint: node.kind.iconTint)
            item.indentationLevel = min(depth, 15)
            item.state = node.id == selectedID ? .on : .off
            menu.addItem(item)
            for child in node.children { add(child, depth: depth + 1) }
        }
        add(container, depth: 0)
        return menu
    }

    static func image(systemName: String, tint: NSColor) -> NSImage? {
        NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [tint]))
    }

    static func fileImage(forFilename filename: String) -> NSImage? {
        let icon = IDEFileIcon.paletteIcon(forFilename: filename)
        let tint: NSColor
        switch icon.tint {
        case .accent: tint = .controlAccentColor
        case .blue: tint = .systemBlue
        case .orange: tint = .systemOrange
        case .green: tint = .systemGreen
        case .purple: tint = .systemPurple
        case .red: tint = .systemRed
        case .secondary: tint = .secondaryLabelColor
        }
        return image(systemName: icon.systemName, tint: tint)
    }
}

extension StructureKind {
    var iconSystemName: String {
        switch self {
        case .type: "c.circle.fill"
        case .field: "f.circle.fill"
        case .method, .constructor: "m.circle.fill"
        case .enumConstant: "e.circle.fill"
        case .recordComponent: "r.circle.fill"
        }
    }

    var iconTint: NSColor {
        switch self {
        case .type: .systemBlue
        case .field: .systemPurple
        case .method, .constructor: .systemOrange
        case .enumConstant: .systemGreen
        case .recordComponent: .systemTeal
        }
    }
}

/// One directory level, listed the first time AppKit is about to show it.
@MainActor
private final class IDEDirectoryMenu: NSMenu, NSMenuDelegate {
    /// Enough for any real source folder; a generated folder with more stops here.
    private static let entryLimit = 500

    private let directory: URL
    private let currentPath: String?
    private let onOpen: (URL) -> Void
    private var isPopulated = false

    init(directory: URL, currentPath: String?, onOpen: @escaping (URL) -> Void) {
        self.directory = directory
        self.currentPath = currentPath
        self.onOpen = onOpen
        super.init(title: directory.lastPathComponent)
        autoenablesItems = false
        delegate = self
        // A submenu needs an item for AppKit to draw its arrow; `populate` replaces it.
        addItem(Self.disabledItem("Loading…"))
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        populate()
    }

    func populate() {
        guard !isPopulated else { return }
        isPopulated = true
        removeAllItems()
        let entries = IDEProjectModel.visibleEntries(of: directory) ?? []
        if entries.isEmpty {
            addItem(Self.disabledItem("Empty"))
            return
        }
        for entry in entries.prefix(Self.entryLimit) {
            let name = entry.url.lastPathComponent
            if entry.isDirectory {
                let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
                item.image = IDEBreadcrumbMenu.image(systemName: "folder", tint: .secondaryLabelColor)
                item.submenu = IDEDirectoryMenu(directory: entry.url, currentPath: currentPath, onOpen: onOpen)
                if let currentPath, currentPath.hasPrefix(entry.url.path + "/") { item.state = .mixed }
                addItem(item)
            } else {
                let url = entry.url
                let onOpen = onOpen
                let item = IDEClosureMenuItem(title: name) { onOpen(url) }
                item.image = IDEBreadcrumbMenu.fileImage(forFilename: name)
                item.state = url.standardizedFileURL.path == currentPath ? .on : .off
                addItem(item)
            }
        }
        if entries.count > Self.entryLimit {
            addItem(Self.disabledItem("\(entries.count - Self.entryLimit) more…"))
        }
    }

    private static func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

/// One package, listed the first time AppKit is about to show it. Subpackages are compacted
/// the same way the status-bar crumbs are when the project tree is in memory.
@MainActor
private final class IDEPackageMenu: NSMenu, NSMenuDelegate {
    private static let entryLimit = 500

    private let directory: URL
    private let node: IDEFileNode?
    private let currentPath: String?
    private let onOpen: (URL) -> Void
    private let onReveal: (URL) -> Void
    private var isPopulated = false

    init(
        directory: URL,
        node: IDEFileNode?,
        currentPath: String?,
        onOpen: @escaping (URL) -> Void,
        onReveal: @escaping (URL) -> Void
    ) {
        self.directory = directory
        self.node = node
        self.currentPath = currentPath
        self.onOpen = onOpen
        self.onReveal = onReveal
        super.init(title: directory.lastPathComponent)
        autoenablesItems = false
        delegate = self
        addItem(Self.disabledItem("Loading…"))
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        populate()
    }

    func populate() {
        guard !isPopulated else { return }
        isPopulated = true
        removeAllItems()
        let items = menuItems()
        if items.isEmpty {
            addItem(Self.disabledItem("Empty"))
        } else {
            for item in items.prefix(Self.entryLimit) {
                addItem(item)
            }
            if items.count > Self.entryLimit {
                addItem(Self.disabledItem("\(items.count - Self.entryLimit) more…"))
            }
        }
        addItem(.separator())
        let directory = directory
        let onReveal = onReveal
        let reveal = IDEClosureMenuItem(title: "Reveal in Explorer") { onReveal(directory) }
        reveal.image = IDEBreadcrumbMenu.image(systemName: "sidebar.left", tint: .secondaryLabelColor)
        addItem(reveal)
    }

    private func menuItems() -> [NSMenuItem] {
        if let node {
            let children = IDEExplorerPresentation.ordered(
                (node.children ?? []).filter { !$0.isExcluded },
                options: IDEExplorerPresentation.Options()
            )
            return children.map(item(for:))
        }
        let entries = IDEProjectModel.visibleEntries(of: directory) ?? []
        return entries.map { entry in
            if entry.isDirectory {
                return packageItem(title: entry.url.lastPathComponent, directory: entry.url, node: nil, holdsCurrentFile: false)
            }
            return fileItem(url: entry.url)
        }
    }

    private func item(for child: IDEFileNode) -> NSMenuItem {
        if child.isDirectory {
            let compacted = IDEExplorerPresentation.compacted(child) { node in
                (node.children ?? []).filter { !$0.isExcluded }
            }
            let holdsCurrent = currentPath.map { $0.hasPrefix(compacted.url.path + "/") } ?? false
            return packageItem(
                title: compacted.displayName ?? compacted.name,
                directory: compacted.url,
                node: compacted,
                holdsCurrentFile: holdsCurrent
            )
        }
        return fileItem(url: child.url)
    }

    private func packageItem(title: String, directory: URL, node: IDEFileNode?, holdsCurrentFile: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = IDEBreadcrumbMenu.image(systemName: "folder", tint: .secondaryLabelColor)
        item.submenu = IDEPackageMenu(
            directory: directory,
            node: node,
            currentPath: currentPath,
            onOpen: onOpen,
            onReveal: onReveal
        )
        item.state = holdsCurrentFile ? .mixed : .off
        return item
    }

    private func fileItem(url: URL) -> NSMenuItem {
        let onOpen = onOpen
        let item = IDEClosureMenuItem(title: url.lastPathComponent) { onOpen(url) }
        item.image = IDEBreadcrumbMenu.fileImage(forFilename: url.lastPathComponent)
        item.state = url.standardizedFileURL.path == currentPath ? .on : .off
        return item
    }

    private static func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

final class IDEClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func fire() {
        handler()
    }
}

/// Remembers the AppKit view behind a SwiftUI control so a menu can pop up against it.
@MainActor
final class IDEMenuAnchor {
    fileprivate weak var view: NSView?

    /// Opens `menu` just above the anchored view (the status bar sits at the window's bottom);
    /// AppKit moves it back on screen when it doesn't fit.
    func popUp(_ menu: NSMenu) {
        guard let view else { return }
        let gap: CGFloat = 4
        let height = menu.size.height
        let y = view.isFlipped ? -gap - height : view.bounds.height + gap + height
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: view)
    }
}

struct IDEMenuAnchorView: NSViewRepresentable {
    let anchor: IDEMenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}
