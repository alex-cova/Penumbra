import AppKit
import SwiftUI
import UniformTypeIdentifiers

public struct IDERootView: View {
    @Environment(IDEWorkspace.self) private var workspace
    @State private var sidebarWidth = IDESessionStore.load().sidebarWidth
    @State private var structureSidebarWidth = IDESessionStore.load().structureSidebarWidth
    @State private var gradleSidebarWidth = IDESessionStore.load().gradleSidebarWidth
    @State private var didBootstrap = false

    public init() {}

    public var body: some View {
        let _ = workspace.layoutEpoch
        let _ = workspace.showsWelcome
        VStack(spacing: 0) {
            IDEToolbarPanel()
                .opacity(workspace.chromeOpacity)
                .allowsHitTesting(workspace.chromeOpacity > 0.05)

            HStack(spacing: 0) {
                if IDEToolWindowStripe.hasItems(edge: .leading, workspace: workspace) {
                    IDEToolWindowStripe(edge: .leading)
                        .opacity(workspace.chromeOpacity)
                        .allowsHitTesting(workspace.chromeOpacity > 0.05)
                } else {
                    IDEAppearance.ColorToken.frame.frame(width: IDEAppearance.Spacing.islandGap)
                }

                workbenchSplits
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if IDEToolWindowStripe.hasItems(edge: .trailing, workspace: workspace) {
                    IDEToolWindowStripe(edge: .trailing)
                        .opacity(workspace.chromeOpacity)
                        .allowsHitTesting(workspace.chromeOpacity > 0.05)
                } else {
                    IDEAppearance.ColorToken.frame.frame(width: IDEAppearance.Spacing.islandGap)
                }
            }
            .padding(.bottom, IDEAppearance.Spacing.islandGap)

            IDEStatusBarPanel()
                .opacity(workspace.chromeOpacity)
                .allowsHitTesting(workspace.chromeOpacity > 0.05)
        }
        .background(IDEAppearance.ColorToken.frame)
        .background(IDEWindowConfigurator(title: workspace.windowTitle, workspace: workspace))
        .overlay {
            IDEPaletteOverlayHost(workspace: workspace)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(true)
        }
        .overlay {
            if workspace.showsFirstRunGuide {
                IDEFirstRunGuideOverlay()
            }
        }
        .sheet(isPresented: Binding(
            get: { workspace.runConfigurationDraft != nil },
            set: { if !$0 { workspace.dismissRunConfigurationSheet() } }
        )) {
            if let configuration = workspace.runConfigurationDraft {
                IDERunConfigurationSheet(configuration: configuration)
                    .environment(workspace)
                    .preferredColorScheme(.dark)
            }
        }
        .sheet(item: Binding(
            get: { workspace.workspaceEditPreview },
            set: { if $0 == nil { workspace.dismissWorkspaceEditPreview() } }
        )) { model in
            IDEWorkspaceEditPreviewSheet(model: model)
                .environment(workspace)
                .preferredColorScheme(.dark)
        }
        .preferredColorScheme(.dark)
        .task {
            guard !didBootstrap else { return }
            didBootstrap = true
            workspace.bootstrap()
            workspace.focusActiveEditor()
        }
        .onChange(of: sidebarWidth) { _, newWidth in
            workspace.saveSession(sidebarWidth: newWidth, structureSidebarWidth: structureSidebarWidth, gradleSidebarWidth: gradleSidebarWidth)
        }
        .onChange(of: structureSidebarWidth) { _, newWidth in
            workspace.structureSidebarWidth = newWidth
            workspace.saveSession(sidebarWidth: sidebarWidth, structureSidebarWidth: newWidth, gradleSidebarWidth: gradleSidebarWidth)
        }
        .onChange(of: gradleSidebarWidth) { _, newWidth in
            workspace.gradleSidebarWidth = newWidth
            workspace.saveSession(sidebarWidth: sidebarWidth, structureSidebarWidth: structureSidebarWidth, gradleSidebarWidth: newWidth)
        }
        .onChange(of: workspace.terminalHeight) { _, newHeight in
            workspace.saveSession(
                sidebarWidth: sidebarWidth,
                structureSidebarWidth: structureSidebarWidth,
                gradleSidebarWidth: gradleSidebarWidth,
                terminalHeight: newHeight
            )
        }
        .focusable(false)
    }

    // MARK: - Splits

    /// Sidebar | structure | (editor over terminal) | Gradle, as nested `SplitPanes`. Every pane
    /// stays in the same place in the view tree whether it is shown or not (`hiddenSide`), so
    /// toggling a tool window never remounts the editor's text views.
    private var workbenchSplits: some View {
        SplitPanes(
            minPrimary: IDEAppearance.Spacing.sidebarMinWidth,
            maxPrimary: IDEAppearance.Spacing.sidebarMaxWidth,
            idealPrimary: sidebarWidth,
            minSecondary: IDEAppearance.Spacing.editorMinLength,
            hiddenSide: workspace.showsSidebar ? nil : .primary,
            onResize: { primary, _ in settle(&sidebarWidth, to: primary) }
        ) {
            chrome(IDESidebarPanel().ideIsland())
        } secondary: {
            SplitPanes(
                minPrimary: IDEAppearance.Spacing.sidebarMinWidth,
                maxPrimary: IDEAppearance.Spacing.sidebarMaxWidth,
                idealPrimary: structureSidebarWidth,
                minSecondary: IDEAppearance.Spacing.editorMinLength,
                hiddenSide: workspace.showsStructureSidebar ? nil : .primary,
                onResize: { primary, _ in settle(&structureSidebarWidth, to: primary) }
            ) {
                chrome(IDEJavaStructurePanel().ideIsland())
            } secondary: {
                SplitPanes(
                    minPrimary: IDEAppearance.Spacing.editorMinLength,
                    minSecondary: IDEAppearance.Spacing.sidebarMinWidth,
                    maxSecondary: IDEAppearance.Spacing.sidebarMaxWidth,
                    idealSecondary: gradleSidebarWidth,
                    priority: .secondary,
                    hiddenSide: workspace.showsGradleSidebar ? nil : .secondary,
                    onResize: { _, secondary in settle(&gradleSidebarWidth, to: secondary) }
                ) {
                    editorColumn
                } secondary: {
                    chrome(IDEGradleSidebarPanel().ideIsland())
                }
            }
        }
    }

    /// The editor island over the terminal / bottom panel.
    private var editorColumn: some View {
        SplitPanes(
            axis: .vertical,
            minPrimary: IDEAppearance.Spacing.editorMinHeight,
            minSecondary: IDEAppearance.Spacing.terminalMinHeight,
            maxSecondary: IDEAppearance.Spacing.terminalMaxHeight,
            idealSecondary: workspace.terminalHeight,
            priority: .secondary,
            hiddenSide: workspace.isTerminalVisible ? nil : .secondary,
            onResize: { _, secondary in
                var height = workspace.terminalHeight
                settle(&height, to: secondary)
                workspace.terminalHeight = height
            }
        ) {
            VStack(spacing: 0) {
                if workspace.isFindInFilesVisible {
                    chrome(FindInFilesPanel())
                }

                if workspace.javaSupport.gradleBuildFilesChanged {
                    chrome(IDEGradleReloadBanner())
                }

                ZStack {
                    // A folder alone is not a document. The workbench always has an empty
                    // pane, so showing it here paints a text editor with no tab and no text.
                    if workspace.hasOpenDocuments {
                        IDEEditorLayoutNode(layout: workspace.editorLayout)
                            .id("editor-layout")
                    } else {
                        IDEWelcomeView()
                    }
                }
                .frame(maxHeight: .infinity)
                .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
            }
            .ideIsland()
        } secondary: {
            chrome(IDETerminalPanel().ideIsland())
        }
    }

    /// Tool-window chrome fades out (and stops taking clicks) in distraction-free mode.
    private func chrome(_ content: some View) -> some View {
        content
            .opacity(workspace.chromeOpacity)
            .allowsHitTesting(workspace.chromeOpacity > 0.05)
    }

    /// Takes a divider position reported by `SplitPanes.onResize`. Nothing is written before
    /// `bootstrap()` — the first layout reports the restored sizes back, and saving then would
    /// store a session with no documents in it — nor for sub-point rounding noise.
    private func settle(_ stored: inout Double, to reported: CGFloat) {
        guard didBootstrap, abs(stored - reported) >= 1 else { return }
        stored = reported
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { item, _ in
                if let url = item {
                    Task { @MainActor in
                        workspace.openDroppedURLs([url])
                    }
                }
            }
        }
        return !providers.isEmpty
    }
}

#Preview {
    IDERootView()
        .environment(IDEWorkspace())
        .frame(width: 1100, height: 700)
}

struct IDEGradleReloadBanner: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            Text("Build files changed — reload Gradle project?")
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .lineLimit(1)
            Spacer(minLength: IDEAppearance.Spacing.sm)
            Button("Reload") {
                workspace.reloadGradleProject()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button("Dismiss") {
                workspace.dismissGradleReloadBanner()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, IDEAppearance.Spacing.md)
        .padding(.vertical, IDEAppearance.Spacing.sm)
        .background(IDEAppearance.ColorToken.tabActive)
        .accessibilityElement(children: .contain)
    }
}

/// Configures the SwiftUI window for a hidden, movable titlebar without a hosting view controller.
private struct IDEWindowConfigurator: NSViewRepresentable {
    let title: String
    let workspace: IDEWorkspace

    func makeCoordinator() -> Coordinator {
        Coordinator(workspace: workspace)
    }

    func makeNSView(context: Context) -> IDEWindowConfiguratorView {
        let view = IDEWindowConfiguratorView()
        view.title = title
        view.closeGuard = context.coordinator.closeGuard
        return view
    }

    func updateNSView(_ view: IDEWindowConfiguratorView, context: Context) {
        view.title = title
        view.closeGuard = context.coordinator.closeGuard
        view.apply(activate: false)
    }

    @MainActor
    final class Coordinator {
        let closeGuard: IDEWindowCloseGuard

        init(workspace: IDEWorkspace) {
            let windowGuard = IDEWindowCloseGuard()
            windowGuard.workspace = workspace
            closeGuard = windowGuard
        }
    }
}

final class IDEWindowConfiguratorView: NSView {
    var title: String = "Umbra"
    var closeGuard: IDEWindowCloseGuard?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply(activate: true)
    }

    func apply(activate: Bool) {
        guard let window else { return }
        if window.title != title {
            window.title = title
        }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        if let closeGuard {
            MainActor.assumeIsolated {
                closeGuard.install(on: window)
            }
        }
        if activate {
            window.makeKeyAndOrderFront(nil)
        }
    }

    override var acceptsFirstResponder: Bool { false }
}

/// Intercepts the red close button so unsaved edits can be confirmed before the window closes.
@MainActor
final class IDEWindowCloseGuard: NSObject, NSWindowDelegate {
    weak var workspace: IDEWorkspace?
    private weak var upstream: NSWindowDelegate?

    func install(on window: NSWindow) {
        guard window.delegate !== self else { return }
        upstream = window.delegate
        window.delegate = self
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard workspace?.confirmCloseWindow() == true else { return false }
        if let upstream, upstream.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))) {
            guard upstream.windowShouldClose?(sender) == true else { return false }
        }
        workspace?.saveSession()
        return true
    }
}

/// Full-window AppKit host for the command palette. Clicks pass through while the palette is
/// hidden; `CommandPaletteController` installs its dimmed backdrop as a subview.
private struct IDEPaletteOverlayHost: NSViewRepresentable {
    let workspace: IDEWorkspace

    func makeNSView(context: Context) -> IDEPaletteHostView {
        let view = IDEPaletteHostView()
        view.workspace = workspace
        return view
    }

    func updateNSView(_ view: IDEPaletteHostView, context: Context) {
        view.workspace = workspace
        view.installIfNeeded()
    }
}

private final class IDEPaletteHostView: NSView {
    weak var workspace: IDEWorkspace?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installIfNeeded()
    }

    func installIfNeeded() {
        workspace?.attachPaletteOverlay(to: self)
    }

    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit === self { return nil }
        return hit
    }
}
