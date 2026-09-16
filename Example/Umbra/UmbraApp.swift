import AppKit
import SwiftUI

@main
struct UmbraApp: App {
    @NSApplicationDelegateAdaptor(IDEAppDelegate.self) private var appDelegate
    @StateObject private var workspace = IDEWorkspace()

    var body: some Scene {
        WindowGroup {
            IDERootView()
                .environmentObject(workspace)
                .frame(minWidth: 960, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New File", systemImage: "doc.badge.plus", action: workspace.newFile)
                    .keyboardShortcut("n")
                Button("Open…", systemImage: "folder", action: workspace.openFile)
                    .keyboardShortcut("o")
                Button("Open Folder…", systemImage: "folder.badge.plus", action: workspace.openFolder)
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Save", systemImage: "square.and.arrow.down") {
                    Task { await workspace.saveActiveDocument() }
                }
                .keyboardShortcut("s")
                Button("Save As…", systemImage: "square.and.arrow.down.on.square") {
                    Task { await workspace.saveActiveDocumentAs() }
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Close Tab", systemImage: "xmark", action: workspace.closeActiveTab)
                    .keyboardShortcut("w")
                if !workspace.recentFileURLs.isEmpty {
                    Divider()
                    Menu("Open Recent") {
                        ForEach(workspace.recentFileURLs, id: \.path) { url in
                            Button(url.lastPathComponent) {
                                workspace.openRecentFile(url)
                            }
                        }
                    }
                }
            }

            CommandGroup(after: .pasteboard) {
                Button("Find…", systemImage: "magnifyingglass", action: workspace.showFind)
                    .keyboardShortcut("f")
                Button("Replace…", systemImage: "arrow.left.arrow.right", action: workspace.showReplace)
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Button("Find in Files…", systemImage: "folder.badge.gearshape", action: workspace.showFindInFiles)
                    .keyboardShortcut("f", modifiers: [.command, .shift])
            }

            CommandMenu("Go") {
                Button("Go to File…", action: workspace.showQuickOpen)
                    .keyboardShortcut("p")
                Button("Go to Symbol…", action: workspace.showGoToSymbol)
                    .keyboardShortcut("r")
                Button("Go to Line…", action: workspace.showGoToLine)
                    .keyboardShortcut("g")
                Button("Command Palette…", action: workspace.showCommandPalette)
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }

            CommandMenu("View") {
                Button("Split Editor Right", systemImage: "rectangle.split.2x1", action: workspace.splitRight)
                    .keyboardShortcut("\\", modifiers: .command)
                Button("Split Editor Down", systemImage: "rectangle.split.1x2", action: workspace.splitDown)
                Button("Close Editor Group", systemImage: "rectangle.slash", action: workspace.closeActivePane)
                Divider()
                Button("Toggle Sidebar", systemImage: "sidebar.leading", action: workspace.toggleSidebar)
                    .keyboardShortcut("b", modifiers: .command)
                Toggle("Line Numbers", isOn: Binding(
                    get: { workspace.preferences.showLineNumbers },
                    set: { _ in workspace.toggleLineNumbers() }
                ))
                Toggle("Code Folding", isOn: Binding(
                    get: { workspace.preferences.isLineFoldingEnabled },
                    set: { _ in workspace.toggleFolding() }
                ))
                Toggle("Word Wrap", isOn: Binding(
                    get: { workspace.preferences.wrapLines },
                    set: { _ in workspace.toggleWordWrap() }
                ))
                Toggle("Minimap", isOn: Binding(
                    get: { workspace.preferences.showMinimap },
                    set: { _ in workspace.toggleMinimap() }
                ))
                Divider()
                Button("Toggle Typewriter Scrolling", action: workspace.toggleTypewriterScrolling)
                Button("Toggle Distraction Free", action: workspace.toggleDistractionFreeMode)
                Toggle("Use Metal Renderer", isOn: Binding(
                    get: { workspace.preferences.isMetalRenderingEnabled },
                    set: { _ in workspace.toggleMetalRendering() }
                ))
            }

            CommandGroup(after: .appInfo) {
                Button("Settings…", action: showSettings)
                    .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(replacing: .help) {
                Button("Umbra on GitHub") {
                    if let url = URL(string: "https://github.com/alex-cova/Runestone") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    private func showSettings() {
        let controller = NSHostingController(rootView: IDEPreferencesView(preferences: workspace.preferences))
        let window = NSWindow(contentViewController: controller)
        window.title = "Umbra Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 460, height: 400))
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}
