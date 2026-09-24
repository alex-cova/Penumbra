/// The tab showing in the bottom panel.
enum IDEBottomPanelTab: Hashable {
    /// A shell -- which one is `IDEWorkspace.selectedTerminalTabID`.
    case terminal
    case gradle
    case http
    case sourceControl
    case problems
}
