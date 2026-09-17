import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct IDERootView: View {
    @EnvironmentObject private var workspace: IDEWorkspace
    @State private var sidebarWidth = IDESessionStore.load().sidebarWidth
    @State private var didBootstrap = false

    var body: some View {
        let _ = workspace.layoutEpoch
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if workspace.showsSidebar {
                    IDESidebarPanel(leadingInset: IDEAppearance.Spacing.trafficLightsInset)
                        .frame(width: sidebarWidth)
                        .opacity(workspace.chromeOpacity)
                        .allowsHitTesting(workspace.chromeOpacity > 0.05)
                        .transition(.move(edge: .leading).combined(with: .opacity))

                    IDESidebarResizeHandle(width: $sidebarWidth)
                        .opacity(workspace.chromeOpacity)
                        .transition(.opacity)
                }

                VStack(spacing: 0) {
                    if workspace.isFindInFilesVisible {
                        FindInFilesPanel(leadingInset: workspace.showsSidebar ? 0 : IDEAppearance.Spacing.trafficLightsInset)
                            .opacity(workspace.chromeOpacity)
                            .allowsHitTesting(workspace.chromeOpacity > 0.05)
                    }

                    ZStack {
                        if workspace.showsWelcome && !workspace.hasOpenDocuments {
                            IDEWelcomeView()
                        } else {
                            IDEEditorLayoutNode(layout: workspace.editorLayout)
                                .id("editor-layout")
                        }
                    }
                    .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
                }
            }
            .animation(IDEAppearance.Motion.spring, value: workspace.showsSidebar)

            IDEStatusBarPanel()
                .opacity(workspace.chromeOpacity)
                .allowsHitTesting(workspace.chromeOpacity > 0.05)
        }
        .background(IDEAppearance.ColorToken.workbench)
        .background(IDEWindowConfigurator(title: workspace.windowTitle))
        .preferredColorScheme(.dark)
        .task {
            guard !didBootstrap else { return }
            didBootstrap = true
            workspace.bootstrap()
            workspace.focusActiveEditor()
        }
        .onChange(of: sidebarWidth) { newWidth in
            workspace.saveSession(sidebarWidth: newWidth)
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
