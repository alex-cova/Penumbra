import AppKit
import Foundation
import JavaIntelligence

/// Breakpoint operations of the window: toggling, enabling, removing and opening breakpoints in the
/// shared store, and mirroring the store for the Breakpoints tab.
extension IDEWorkspace {
    /// Enabled line breakpoints, keyed by file path. Empty while breakpoints are muted.
    func enabledLineBreakpointsByPath() -> [String: [Int]] {
        guard !breakpointsMuted else { return [:] }
        var lines: [String: [Int]] = [:]
        for breakpoint in breakpoints where breakpoint.isEnabled && breakpoint.kind == .line && !breakpoint.filePath.isEmpty {
            lines[breakpoint.filePath, default: []].append(breakpoint.line)
        }
        return lines
    }

    func toggleBreakpoint(atLine line: Int, file url: URL) {
        _ = breakpointStore.toggle(atLine: line, file: url, project: project.rootURL)
        refreshBreakpoints()
    }

    func refreshBreakpoints() {
        breakpoints = breakpointStore.breakpoints(forProject: project.rootURL)
        breakpointsMuted = breakpointStore.isMuted(project: project.rootURL)
        syncBreakpointsToDebugger()
    }

    func setBreakpointEnabled(_ breakpoint: JavaBreakpoint, enabled: Bool) {
        breakpointStore.setEnabled(enabled, breakpointID: breakpoint.id, project: project.rootURL)
        refreshBreakpoints()
        refreshBreakpointGutters()
    }

    func removeBreakpoint(_ breakpoint: JavaBreakpoint) {
        breakpointStore.remove(breakpointID: breakpoint.id, project: project.rootURL)
        refreshBreakpoints()
        refreshBreakpointGutters()
    }

    func removeAllBreakpoints() {
        breakpointStore.removeAll(project: project.rootURL)
        refreshBreakpoints()
        refreshBreakpointGutters()
    }

    func openBreakpoint(_ breakpoint: JavaBreakpoint) {
        revealDebugStop(file: URL(fileURLWithPath: breakpoint.filePath), line: breakpoint.line)
    }

    /// Redraws the breakpoint dots of every open Java or Swift file after the Breakpoints tab changed them.
    func refreshBreakpointGutters() {
        for pane in workbench.panes {
            guard let url = pane.selectedDocument?.url,
                  let textView = hostCache.peek(pane.id)?.textView else { continue }
            let ext = url.pathExtension.lowercased()
            guard ["java", "swift", "js", "mjs", "cjs", "jsx", "ts", "mts", "cts", "tsx"].contains(ext) else { continue }
            Task { await refreshJavaTestDecorations(from: textView, fileURL: url, isJava: ext == "java") }
        }
    }
}
