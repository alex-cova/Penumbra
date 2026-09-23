import AppKit
import SwiftUI
import UniformTypeIdentifiers

public struct IDERootView: View {
    @Environment(IDEWorkspace.self) private var workspace
    @State private var sidebarWidth = IDESessionStore.load().sidebarWidth
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
                if workspace.showsSidebar {
                    IDESidebarPanel()
                        .frame(width: sidebarWidth)
                        .opacity(workspace.chromeOpacity)
                        .allowsHitTesting(workspace.chromeOpacity > 0.05)

                    IDESidebarResizeHandle(width: $sidebarWidth)
                        .opacity(workspace.chromeOpacity)
                }

                VStack(spacing: 0) {
                    if workspace.isFindInFilesVisible {
                        FindInFilesPanel()
                            .opacity(workspace.chromeOpacity)
                            .allowsHitTesting(workspace.chromeOpacity > 0.05)
                    }

                    if workspace.javaSupport.gradleBuildFilesChanged {
                        IDEGradleReloadBanner()
                            .opacity(workspace.chromeOpacity)
                            .allowsHitTesting(workspace.chromeOpacity > 0.05)
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

                    if workspace.isTerminalVisible {
                        IDETerminalResizeHandle(height: Binding(
                            get: { workspace.terminalHeight },
                            set: { workspace.terminalHeight = $0 }
                        ))
                        .opacity(workspace.chromeOpacity)
                    }

                    if workspace.isTerminalVisible {
                        IDETerminalPanel()
                            .frame(height: workspace.terminalHeight)
                            .opacity(workspace.chromeOpacity)
                            .allowsHitTesting(workspace.chromeOpacity > 0.05)
                    }
                }
            }

            IDEStatusBarPanel()
                .opacity(workspace.chromeOpacity)
                .allowsHitTesting(workspace.chromeOpacity > 0.05)
        }
        .background(IDEAppearance.ColorToken.workbench)
        .background(IDEWindowConfigurator(title: workspace.windowTitle))
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
        .preferredColorScheme(.dark)
        .task {
            guard !didBootstrap else { return }
            didBootstrap = true
            workspace.bootstrap()
            workspace.focusActiveEditor()
        }
        .onChange(of: sidebarWidth) { _, newWidth in
            workspace.saveSession(sidebarWidth: newWidth)
        }
        .onChange(of: workspace.terminalHeight) { _, newHeight in
            workspace.saveSession(terminalHeight: newHeight)
        }
        .focusable(false)
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
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(IDEAppearance.ColorToken.border)
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct IDETerminalResizeHandle: View {
    @Binding var height: Double
    @State private var lastTranslation: CGFloat = 0

    var body: some View {
        ZStack {
            Color.clear.frame(height: 6)
            Rectangle()
                .fill(IDEAppearance.ColorToken.border)
                .frame(height: 1)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let delta = lastTranslation - value.translation.height
                    lastTranslation = value.translation.height
                    height = min(
                        max(height + delta, IDEAppearance.Spacing.terminalMinHeight),
                        IDEAppearance.Spacing.terminalMaxHeight
                    )
                }
                .onEnded { _ in
                    lastTranslation = 0
                }
        )
        .onHover { hovering in
            if hovering {
                NSCursor.resizeUpDown.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

private struct IDESidebarResizeHandle: View {
    @Binding var width: Double
    @State private var lastTranslation: CGFloat = 0

    var body: some View {
        ZStack {
            Color.clear.frame(width: 6)
            Rectangle()
                .fill(IDEAppearance.ColorToken.border)
                .frame(width: 1)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let delta = value.translation.width - lastTranslation
                    lastTranslation = value.translation.width
                    width = min(
                        max(width + delta, IDEAppearance.Spacing.sidebarMinWidth),
                        IDEAppearance.Spacing.sidebarMaxWidth
                    )
                }
                .onEnded { _ in
                    lastTranslation = 0
                }
        )
        .onHover { hovering in
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

/// Configures the SwiftUI window for a hidden, movable titlebar without a hosting view controller.
private struct IDEWindowConfigurator: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> IDEWindowConfiguratorView {
        let view = IDEWindowConfiguratorView()
        view.title = title
        return view
    }

    func updateNSView(_ view: IDEWindowConfiguratorView, context: Context) {
        view.title = title
        view.apply(activate: false)
    }
}

final class IDEWindowConfiguratorView: NSView {
    var title: String = "Umbra"

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
        if activate {
            window.makeKeyAndOrderFront(nil)
        }
    }

    override var acceptsFirstResponder: Bool { false }
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
