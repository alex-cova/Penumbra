import Foundation

extension IDEWorkspace {
    /// File ▸ New Project…, the welcome screen's row and the palette command.
    func showNewProject() {
        isNewProjectSheetPresented = true
    }

    func dismissNewProject() {
        isNewProjectSheetPresented = false
    }
}
