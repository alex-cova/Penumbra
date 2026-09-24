/// The tab showing in the bottom panel.
enum IDEBottomPanelTab: Hashable {
    /// A shell -- which one is `IDEWorkspace.selectedTerminalTabID`.
    case terminal
    case gradle
    case http
    case sourceControl
    case problems
    /// The supertype/subtype tree of the type last asked for with ⌃H.
    case typeHierarchy
    /// The results of the last Find Usages.
    case usages
    /// The results of the last test run.
    case testResults
    /// Debugger call stack and variables.
    case debug
    /// Callers and callees of the method last asked for.
    case callHierarchy
}
