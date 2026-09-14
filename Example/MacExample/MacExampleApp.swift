import SwiftUI

@main
struct MacExampleApp: App {
    @NSApplicationDelegateAdaptor(IDEAppDelegate.self) private var appDelegate
    @StateObject private var workspace = IDEWorkspace()

    var body: some Scene {
        WindowGroup {
            IDEMainViewControllerRepresentable(workspace: workspace)
                .frame(minWidth: 960, minHeight: 640)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…", systemImage: "folder", action: workspace.openFile)
                    .keyboardShortcut("o")
                Button("Save", systemImage: "square.and.arrow.down", action: save)
                    .keyboardShortcut("s")
            }
            CommandGroup(after: .pasteboard) {
                Button("Close Tab", systemImage: "xmark", action: workspace.closeActiveTab)
                    .keyboardShortcut("w")
            }
            CommandMenu("View") {
                Button("Command Palette", systemImage: "command", action: workspace.showCommandPalette)
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Divider()
                Button("Split Editor Right", systemImage: "rectangle.split.2x1", action: workspace.splitRight)
                    .keyboardShortcut("\\", modifiers: .command)
                Button("Split Editor Down", systemImage: "rectangle.split.1x2", action: workspace.splitDown)
                Button("Close Editor Group", systemImage: "rectangle.slash", action: workspace.closeActivePane)
                Divider()
                Button("Toggle Sidebar", systemImage: "sidebar.leading", action: workspace.toggleSidebar)
                    .keyboardShortcut("b", modifiers: .command)
                Button("Toggle Minimap", systemImage: "map", action: workspace.toggleMinimap)
                Divider()
                Button("Toggle Typewriter Scrolling", action: workspace.toggleTypewriterScrolling)
                Button("Toggle Distraction Free", action: workspace.toggleDistractionFreeMode)
                Toggle("Use Metal Renderer", isOn: $workspace.isMetalRenderingEnabled)
            }
        }
    }

    private func save() {
        Task {
            await workspace.saveActiveDocument()
        }
    }
}
