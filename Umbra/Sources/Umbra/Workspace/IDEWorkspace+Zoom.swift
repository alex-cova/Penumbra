/// Editor zoom: stepping the shared zoom percent, resetting it, and re-theming every
/// editor host. Pure move out of the core file; the only collaborators are the
/// preferences and the layout hosts.
extension IDEWorkspace {
    func zoomIn() { changeZoom(bySteps: 1) }
    func zoomOut() { changeZoom(bySteps: -1) }

    func resetZoom() {
        preferences.zoomPercent = 100
        applyZoom()
    }

    func changeZoom(bySteps steps: Int) {
        preferences.zoomPercent = IDEPreferences.zoomed(preferences.zoomPercent, bySteps: steps)
        applyZoom()
    }

    /// Rebuilds the editor theme at the zoomed size and repaints every editor.
    func applyZoom() {
        preferences.applyTheme()
        applyPreferencesToAllHosts()
        host(for: workbench.activePaneID).intelligenceController?.showHint("Zoom \(preferences.zoomPercent)%")
    }
}
