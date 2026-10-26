import AppKit
import Penumbra

/// Select In… (⌥F1): where to show the file in the editor: the Explorer, Finder, the Structure
/// tab or a terminal opened in its folder.
extension IDEWorkspace {
    func showSelectIn() {
        guard let url = workbench.activePane.selectedDocument?.url, let paletteController else {
            NSSound.beep()
            return
        }
        let folder = url.deletingLastPathComponent()
        var entries: [(title: String, subtitle: String?, run: () -> Void)] = []
        if project.rootURL != nil {
            entries.append(("Project Explorer", "Select \(url.lastPathComponent) in the sidebar", { [weak self] in
                self?.revealActiveFileInExplorer()
            }))
        }
        entries.append(("Finder", url.path, { NSWorkspace.shared.activateFileViewerSelecting([url]) }))
        entries.append(("Structure", "The declarations of \(url.lastPathComponent)", { [weak self] in
            self?.showSidebarTab(.structure)
        }))
        entries.append(("Terminal", folder.path, { [weak self] in
            self?.showTerminal()
            self?.addTerminalTab(cwd: folder)
        }))
        paletteController.presentList(title: "Select In", items: entries.map { (title: $0.title, subtitle: $0.subtitle) }) { index in
            guard entries.indices.contains(index) else { return }
            entries[index].run()
        }
    }
}
