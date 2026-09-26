import Penumbra

/// One tool window as the stripe and the Recent Files (⌘E) sidebar both show it. Built fresh from
/// the workspace's state, so only the tool windows available right now are listed.
struct IDEToolWindow: Identifiable {
    enum Placement {
        case leadingTop
        case leadingBottom
        case trailingTop
        case trailingBottom
    }

    let id: String
    let systemImage: String
    let title: String
    /// Menu shortcut, shown beside the Recent Files sidebar row.
    let shortcut: String?
    let tint: PaletteIcon.Tint
    let placement: Placement
    let isOpen: Bool
    let toggle: () -> Void
}

extension IDEWorkspace {
    /// Available tool windows in stripe order (leading top, leading bottom, trailing).
    var toolWindows: [IDEToolWindow] {
        var windows: [IDEToolWindow] = []
        // The whole leading stripe stays hidden until a folder or a file is open.
        if hasOpenProject || hasOpenDocuments {
            windows.append(IDEToolWindow(
                id: "explorer", systemImage: "folder", title: "Explorer", shortcut: "⌘0", tint: .blue,
                placement: .leadingTop, isOpen: showsSidebar, toggle: toggleSidebar
            ))
            windows.append(IDEToolWindow(
                id: "find", systemImage: "magnifyingglass", title: "Find in Files", shortcut: "⌘⇧F",
                tint: .secondary, placement: .leadingTop, isOpen: isFindInFilesVisible, toggle: toggleFindInFiles
            ))
            if showsJavaStructureButton {
                windows.append(IDEToolWindow(
                    id: "structure", systemImage: "list.bullet.indent", title: "Structure", shortcut: "⌘7",
                    tint: .secondary, placement: .leadingTop, isOpen: showsStructureSidebar,
                    toggle: toggleStructureSidebar
                ))
            }
            if showsSourceControlTab {
                windows.append(bottomToolWindow(
                    .sourceControl, "arrow.triangle.branch", "Source Control", "⌃⌘G", .green, .leadingTop
                ))
            }
            if showsDebugTab {
                windows.append(bottomToolWindow(.debug, "ladybug", "Debug", nil, .red, .leadingBottom))
            }
            if showsTestResultsTab {
                windows.append(bottomToolWindow(.testResults, "flask", "Test Results", nil, .green, .leadingBottom))
            }
            if showsUsagesTab {
                windows.append(bottomToolWindow(.usages, "text.magnifyingglass", "Usages", nil, .secondary, .leadingBottom))
            }
            if showsTypeHierarchyTab {
                windows.append(bottomToolWindow(.typeHierarchy, "list.bullet.indent", "Hierarchy", nil, .secondary, .leadingBottom))
            }
            if showsCallHierarchyTab {
                windows.append(bottomToolWindow(
                    .callHierarchy, "phone.arrow.down.left", "Call Hierarchy", nil, .secondary, .leadingBottom
                ))
            }
            windows.append(bottomToolWindow(
                .problems, "exclamationmark.triangle", "Problems", "⌘⇧M", .orange, .leadingBottom
            ))
            windows.append(bottomToolWindow(.terminal, "terminal", "Terminal", "⌃`", .secondary, .leadingBottom))
        }
        if javaSupport.isGradleProject {
            windows.append(IDEToolWindow(
                id: "gradle", systemImage: "square.stack.3d.up", title: "Gradle", shortcut: nil, tint: .purple,
                placement: .trailingTop, isOpen: showsGradleSidebar, toggle: toggleGradleSidebar
            ))
        }
        if showsGradleConsoleTab {
            windows.append(bottomToolWindow(.gradle, "text.alignleft", "Gradle Console", nil, .purple, .trailingBottom))
        }
        if showsHTTPTab {
            windows.append(bottomToolWindow(.http, "network", "HTTP Response", nil, .blue, .trailingBottom))
        }
        return windows
    }

    /// Opens (`true`) or hides (`false`) a tool window; no-op when it is already in that state or
    /// no longer available. Unlike the stripe buttons, choosing an open tool window keeps it open.
    func setToolWindow(_ id: String, open: Bool) {
        guard let window = toolWindows.first(where: { $0.id == id }), window.isOpen != open else { return }
        window.toggle()
    }

    private func bottomToolWindow(
        _ tab: IDEBottomPanelTab,
        _ systemImage: String,
        _ title: String,
        _ shortcut: String?,
        _ tint: PaletteIcon.Tint,
        _ placement: IDEToolWindow.Placement
    ) -> IDEToolWindow {
        IDEToolWindow(
            id: "\(tab)", systemImage: systemImage, title: title, shortcut: shortcut, tint: tint,
            placement: placement, isOpen: isBottomToolWindowOpen(tab),
            toggle: { [weak self] in self?.toggleBottomToolWindow(tab) }
        )
    }
}
