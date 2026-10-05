import AppKit
import SwiftUI
import UniformTypeIdentifiers

public struct IDERootView: View {
    @State private var agentPanelWidth: Double
    @Environment(IDEWorkspace.self) private var workspace
    @State private var sidebarWidth: Double
    @State private var gradleSidebarWidth: Double
    @State private var didRecordPanelSizes = false
    @State private var didBootstrap = false
    /// The window's top safe-area inset: the system titlebar, plus the native tab bar while it
    /// shows. `toolbarRowHeight` and `topChromeHeight` derive from it.
    @State private var topInset = IDEAppearance.Spacing.titlebarMinHeight

    private var chrome: IDEWindowChrome {
        IDEWindowChrome(topInset: topInset, isFullScreen: workspace.isFullScreen)
    }

    /// Everything above the panels: the toolbar row plus the native tab bar's strip.
    private var topChromeHeight: CGFloat {
        chrome.toolbarRowHeight + chrome.tabBarHeight
    }

    public init() {
        let session = IDEWindowSessionStore.load()
        _sidebarWidth = State(initialValue: session.sidebarWidth)
        _gradleSidebarWidth = State(initialValue: session.gradleSidebarWidth)
        _agentPanelWidth = State(initialValue: session.agentPanelWidth ?? IDEAppearance.Spacing.agentPanelWidth)
    }

    private var isAgentPageShown: Bool { workspace.agent.coversEditor && workspace.hasOpenProject }
    private var isAgentDocked: Bool { workspace.agent.isPanelVisible && !workspace.agent.settings.opensAsPage && workspace.hasOpenProject }

    public var body: some View {
        let _ = workspace.layoutEpoch
        let _ = workspace.showsWelcome
        let _ = workspace.preferences.uiFontName
        let _ = workspace.preferences.uiFontSize
        let _ = workspace.preferences.uiColorSchemeID
        let _ = workspace.uiColorSchemeEpoch
        VStack(spacing: 0) {
            // Full screen: the native tab bar is the topmost strip and the toolbar row sits under it.
            if chrome.hasTabBarAboveToolbar {
                Color.clear.frame(height: chrome.tabBarHeight)
            }
            IDEToolbarPanel()
                .frame(height: chrome.toolbarRowHeight)
                .padding(.bottom, chrome.hasTabBarBelowToolbar ? 0 : IDEAppearance.Spacing.xs)
                .opacity(workspace.chromeOpacity)
                .allowsHitTesting(workspace.chromeOpacity > 0.05)
            // Windowed: the native tab bar hangs right under the system titlebar, over this strip.
            if chrome.hasTabBarBelowToolbar {
                Color.clear.frame(height: chrome.tabBarHeight + IDEAppearance.Spacing.xs)
            }

            HStack(spacing: 0) {
                Color.clear.frame(width: IDEAppearance.Spacing.panelGap)

                if workspace.showsSidebar {
                    IDELeftSidebar()
                        .frame(width: sidebarWidth)
                        .idePanel()
                        .opacity(workspace.chromeOpacity)
                        .allowsHitTesting(workspace.chromeOpacity > 0.05)

                    IDESidebarResizeHandle(width: $sidebarWidth, edge: .leading)
                }

                VStack(spacing: 0) {
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
                                    .id(workspace.layoutEpoch)
                            } else {
                                IDEWelcomeView()
                            }
                        }
                        .allowsHitTesting(!workspace.isSettingsVisible && !isAgentPageShown)
                        .accessibilityHidden(workspace.isSettingsVisible || isAgentPageShown)
                        .overlay {
                            if workspace.isSettingsVisible {
                                IDEPreferencesView(preferences: workspace.preferences)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background(IDEAppearance.ColorToken.workbench)
                                    .transition(.opacity)
                            } else if isAgentPageShown {
                                // Expanded chat covers the editor, which stays mounted. Side Panel docks it.
                                IDEAgentPage(agent: workspace.agent, onClose: workspace.hideAgentPage)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .transition(.opacity)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
                    }
                    .idePanel()
                    .allowsHitTesting(!workspace.isBottomPanelExpanded)
                    .accessibilityHidden(workspace.isBottomPanelExpanded)

                    if workspace.isTerminalVisible {
                        IDETerminalResizeHandle(height: Binding(
                            get: { workspace.terminalHeight },
                            set: { workspace.terminalHeight = $0 }
                        ))
                        .allowsHitTesting(!workspace.isBottomPanelExpanded)

                        // The panel itself is drawn by the overlay below, so it can grow over the
                        // editor without resizing it; this only keeps its space.
                        Color.clear.frame(height: workspace.terminalHeight)
                    }
                }
                .overlay(alignment: .bottom) {
                    if workspace.isTerminalVisible {
                        let expanded = workspace.isBottomPanelExpanded
                        IDETerminalPanel()
                            .frame(
                                minHeight: expanded ? 0 : workspace.terminalHeight,
                                maxHeight: expanded ? .infinity : workspace.terminalHeight
                            )
                            .idePanel()
                            .opacity(workspace.chromeOpacity)
                            .allowsHitTesting(workspace.chromeOpacity > 0.05)
                    }
                }

                if isAgentDocked {
                    IDESidebarResizeHandle(width: $agentPanelWidth, edge: .trailing)

                    IDEAgentPanel(agent: workspace.agent)
                        .frame(width: agentPanelWidth)
                        .idePanel()
                        .transition(.opacity)
                        .opacity(workspace.chromeOpacity)
                        .allowsHitTesting(workspace.chromeOpacity > 0.05)
                }

                if workspace.showsGradleSidebar {
                    IDESidebarResizeHandle(width: $gradleSidebarWidth, edge: .trailing)

                    IDEGradleSidebarPanel()
                        .frame(width: gradleSidebarWidth)
                        .idePanel()
                        .opacity(workspace.chromeOpacity)
                        .allowsHitTesting(workspace.chromeOpacity > 0.05)
                }

                Color.clear.frame(width: IDEAppearance.Spacing.panelGap)
            }

            IDEStatusBarPanel()
                .id(workspace.uiColorSchemeEpoch)
                .opacity(workspace.chromeOpacity)
                .allowsHitTesting(workspace.chromeOpacity > 0.05)
        }
        .ignoresSafeArea(.container, edges: .top)
        .onGeometryChange(for: CGFloat.self, of: \.safeAreaInsets.top) { inset in
            // Full screen hides the titlebar (inset 0) but keeps the row.
            topInset = inset
        }
        // The frame color is `NSWindow.backgroundColor` (set in `IDEWindowConfiguratorView`); an
        // opaque SwiftUI fill here would paint over the traffic lights.
        .background(IDEWindowConfigurator(
            title: workspace.windowTitle,
            workspace: workspace,
            uiColorSchemeID: workspace.preferences.uiColorSchemeID
        ))
        .overlay {
            IDEPaletteOverlayHost(workspace: workspace)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(true)
        }
        .overlay(alignment: .topTrailing) {
            IDEStatusToast()
                .padding(.top, topChromeHeight + IDEAppearance.Spacing.xs)
                .padding(.trailing, IDEAppearance.Spacing.panelGap + IDEAppearance.Spacing.xs)
                .opacity(workspace.chromeOpacity)
                .allowsHitTesting(workspace.chromeOpacity > 0.05)
        }
        .overlay(alignment: .topTrailing) {
            if workspace.notifications.isPanelPresented {
                ZStack(alignment: .topTrailing) {
                    // Any click outside the card closes it.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { workspace.notifications.setPanelPresented(false) }
                    IDENotificationPanel()
                        .padding(.top, topChromeHeight + IDEAppearance.Spacing.xs)
                        .padding(.trailing, IDEAppearance.Spacing.panelGap + IDEAppearance.Spacing.xs)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                .opacity(workspace.chromeOpacity)
                .allowsHitTesting(workspace.chromeOpacity > 0.05)
                .onExitCommand { workspace.notifications.setPanelPresented(false) }
            }
        }
        .animation(.easeOut(duration: 0.15), value: workspace.notifications.isPanelPresented)
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
                    .preferredColorScheme(IDEAppearance.preferredColorScheme)
            }
        }
        .sheet(isPresented: Binding(
            get: { workspace.gradleRunTaskPrompt != nil },
            set: { if !$0 { workspace.dismissGradleRunTaskPrompt() } }
        )) {
            if let prompt = workspace.gradleRunTaskPrompt {
                IDEGradleTaskPickerSheet(prompt: prompt)
                    .environment(workspace)
                    .preferredColorScheme(IDEAppearance.preferredColorScheme)
            }
        }
        .sheet(item: Binding(
            get: { workspace.workspaceEditPreview },
            set: { if $0 == nil { workspace.dismissWorkspaceEditPreview() } }
        )) { model in
            IDEWorkspaceEditPreviewSheet(model: model)
                .environment(workspace)
                .preferredColorScheme(IDEAppearance.preferredColorScheme)
        }
        .environment(\.colorScheme, IDEAppearance.preferredColorScheme)
        .preferredColorScheme(IDEAppearance.preferredColorScheme)
        .onChange(of: workspace.preferences.uiColorSchemeID) { _, _ in
            workspace.refreshUIColorScheme()
        }
        .task {
            guard !didBootstrap else { return }
            didBootstrap = true
            workspace.bootstrap()
            workspace.focusActiveEditor()
        }
        .onChange(of: sidebarWidth) { _, newWidth in
            workspace.sidebarWidth = newWidth
        }
        .onChange(of: gradleSidebarWidth) { _, newWidth in
            workspace.gradleSidebarWidth = newWidth
        }
        .onChange(of: agentPanelWidth) { _, newWidth in
            workspace.agentPanelWidth = newWidth
        }
        // Building and writing the session is far too heavy to do on every tick of a resize drag,
        // so it waits for the sizes to settle. `task(id:)` cancels the pending save on each change.
        .task(id: PanelSizes(sidebar: sidebarWidth, gradle: gradleSidebarWidth, terminal: workspace.terminalHeight, agent: agentPanelWidth)) {
            // The first run is the launch state, not a change: record it and save nothing.
            guard didRecordPanelSizes else {
                didRecordPanelSizes = true
                return
            }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            workspace.saveSession(
                sidebarWidth: sidebarWidth,
                gradleSidebarWidth: gradleSidebarWidth,
                terminalHeight: workspace.terminalHeight
            )
        }
        .focusable(false)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { item, _ in
                if let url = item {
                    Task { @MainActor in
                        workspace.openURLsDropped([url])
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

private struct PanelSizes: Hashable {
    var sidebar: Double
    var gradle: Double
    var terminal: Double
    var agent: Double
}

private struct IDETerminalResizeHandle: View {
    @Binding var height: Double
    /// The height when the drag began; the drag is applied as start + total movement.
    @State private var startHeight: Double?

    var body: some View {
        // The gap between the editor card and the bottom panel is the handle.
        IDEResizeDragArea(axis: .vertical) { movement in
            let start = startHeight ?? height
            startHeight = start
            height = min(
                max(start - movement, IDEAppearance.Spacing.terminalMinHeight),
                IDEAppearance.Spacing.terminalMaxHeight
            )
        } onEnd: {
            startHeight = nil
        }
        .frame(height: IDEAppearance.Spacing.panelGap)
        .frame(maxWidth: .infinity)
    }
}

private struct IDESidebarResizeHandle: View {
    enum Edge {
        case leading, trailing
    }

    @Binding var width: Double
    var edge: Edge = .leading
    /// The width when the drag began; see `IDETerminalResizeHandle.startHeight`.
    @State private var startWidth: Double?

    var body: some View {
        // The gap between two cards is the handle.
        IDEResizeDragArea(axis: .horizontal) { movement in
            let start = startWidth ?? width
            startWidth = start
            let delta = edge == .leading ? movement : -movement
            width = min(
                max(start + delta, IDEAppearance.Spacing.sidebarMinWidth),
                IDEAppearance.Spacing.sidebarMaxWidth
            )
        } onEnd: {
            startWidth = nil
        }
        .frame(width: IDEAppearance.Spacing.panelGap)
    }
}

/// The drag target of a panel resize handle, in AppKit. A SwiftUI `DragGesture` on these handles
/// misbehaved: the handle moves as its panel resizes, so its own coordinate space moves under the
/// cursor, and the window is `isMovableByWindowBackground`, so a transparent gap can start a
/// window drag. This view refuses window dragging, measures the mouse in window space (which
/// neither the handle nor the panels move) and owns the resize cursor.
private struct IDEResizeDragArea: NSViewRepresentable {
    enum Axis { case horizontal, vertical }

    let axis: Axis
    /// Total movement since the mouse went down, along `axis`, positive to the right / downwards.
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void

    init(axis: Axis, onDrag: @escaping (CGFloat) -> Void, onEnd: @escaping () -> Void) {
        self.axis = axis
        self.onDrag = onDrag
        self.onEnd = onEnd
    }

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.axis = axis
        view.onDrag = onDrag
        view.onEnd = onEnd
        return view
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.axis = axis
        view.onDrag = onDrag
        view.onEnd = onEnd
    }

    final class DragView: NSView {
        var axis: Axis = .horizontal
        var onDrag: (CGFloat) -> Void = { _ in }
        var onEnd: () -> Void = {}
        private var startLocation: NSPoint?

        private var cursor: NSCursor { axis == .horizontal ? .resizeLeftRight : .resizeUpDown }

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: cursor)
        }

        override func mouseDown(with event: NSEvent) {
            startLocation = event.locationInWindow
            cursor.set()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let startLocation else { return }
            let location = event.locationInWindow
            // Window coordinates grow upwards; report downwards-positive movement.
            let movement = axis == .horizontal ? location.x - startLocation.x : startLocation.y - location.y
            cursor.set()
            onDrag(movement)
        }

        override func mouseUp(with event: NSEvent) {
            guard startLocation != nil else { return }
            startLocation = nil
            onEnd()
        }
    }
}

/// What AppKit's own chrome takes from the window's top edge, split into the system titlebar and
/// the native tab bar, which appears once two project windows are merged into one tab group.
///
/// Derived from the top inset alone (titlebar plus tab bar), so it cannot disagree with the layout
/// the way a separate "tab bar visible" flag can while a tab is being moved in or out.
///
/// In a window the tab bar hangs right under the system titlebar, so the toolbar row shrinks to the
/// titlebar's height and the tab bar takes the strip below it. In full screen there is no titlebar
/// and the tab bar is the topmost strip, so the row keeps its height and sits under it.
struct IDEWindowChrome: Equatable {
    /// The window's top safe-area inset.
    var topInset: CGFloat
    var isFullScreen: Bool

    /// The height of a plain titled window's titlebar.
    @MainActor
    static var standardTitlebarHeight: CGFloat {
        NSWindow.frameRect(forContentRect: .zero, styleMask: [.titled]).height
    }

    /// Height of the tab bar while it shows (two or more tabs), else 0.
    @MainActor
    var tabBarHeight: CGFloat {
        let extra = isFullScreen ? topInset : topInset - Self.standardTitlebarHeight
        return extra > 1 ? extra : 0
    }

    @MainActor var hasTabBarBelowToolbar: Bool { tabBarHeight > 0 && !isFullScreen }
    @MainActor var hasTabBarAboveToolbar: Bool { tabBarHeight > 0 && isFullScreen }

    @MainActor
    var toolbarRowHeight: CGFloat {
        if hasTabBarBelowToolbar {
            return topInset - tabBarHeight
        }
        return max(topInset, IDEAppearance.Spacing.titlebarMinHeight)
    }
}

/// Configures the SwiftUI window for a hidden, movable titlebar without a hosting view controller.
private struct IDEWindowConfigurator: NSViewRepresentable {
    let title: String
    let workspace: IDEWorkspace
    let uiColorSchemeID: String

    func makeCoordinator() -> Coordinator {
        Coordinator(workspace: workspace)
    }

    func makeNSView(context: Context) -> IDEWindowConfiguratorView {
        let view = IDEWindowConfiguratorView()
        view.title = title
        view.workspace = workspace
        view.closeGuard = context.coordinator.closeGuard
        return view
    }

    func updateNSView(_ view: IDEWindowConfiguratorView, context: Context) {
        view.title = title
        view.workspace = workspace
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
    /// Every Umbra window shares this identifier, so AppKit can merge project windows into one tab
    /// group (Window > Merge All Windows, or the system "Prefer tabs" setting).
    static let tabbingIdentifier = "com.umbra.editor.project-window"

    var title: String = "Umbra"
    weak var workspace: IDEWorkspace?
    var closeGuard: IDEWindowCloseGuard?

    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply(activate: true)
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return }
        window.tabbingIdentifier = Self.tabbingIdentifier
        window.tabbingMode = .automatic
        if let workspace {
            workspace.window = window
            // A window opened as a tab (File > New Window Tab, the tab bar's +) joins its group here.
            if let parent = MainActor.assumeIsolated({ IDEWindowRegistry.shared.takePendingTabParent() }),
               parent !== window {
                parent.addTabbedWindow(window, ordered: .above)
                window.makeKeyAndOrderFront(nil)
            }
            if window.isKeyWindow {
                IDEWindowRegistry.shared.didBecomeActive(workspace)
            }
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                if let workspace = self?.workspace {
                    IDEWindowRegistry.shared.didBecomeActive(workspace)
                }
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.workspace?.windowWillClose() }
        })
        // AppKit lays the traffic lights out again on resize and when leaving full screen.
        let names: [Notification.Name] = [
            NSWindow.didResizeNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didEndLiveResizeNotification
        ]
        observers += names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateFullScreen()
                    self?.centerTrafficLights()
                }
            }
        }
        updateFullScreen()
        // ...and it moves the buttons itself after those notifications, so follow their frames too.
        if let titlebar = window.standardWindowButton(.closeButton)?.superview {
            titlebar.postsFrameChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: titlebar, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.centerTrafficLights() }
            })
        }
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type) else { continue }
            button.postsFrameChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: button, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.centerTrafficLights() }
            })
        }
    }

    /// The titlebar row is taller than the system titlebar, and AppKit keeps the titlebar view at
    /// its own height, so the traffic lights are placed by their distance from the window's top
    /// edge rather than by growing the titlebar: their centers sit on the row's center line, in
    /// line with the toolbar's controls.
    private func centerTrafficLights() {
        guard let window, !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton),
              let titlebar = close.superview else { return }
        // With the tab bar showing the toolbar row is the system titlebar's height, so the lights
        // keep their native spot; otherwise they follow the taller row. The titlebar view is the
        // titlebar plus the tab bar, so its height is the same inset the root view lays out with.
        let chrome = IDEWindowChrome(topInset: titlebar.frame.height, isFullScreen: false)
        let centerFromTop = chrome.toolbarRowHeight / 2
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type), button.superview === titlebar else { continue }
            let y = (titlebar.bounds.height - centerFromTop - button.frame.height / 2).rounded()
            if abs(button.frame.origin.y - y) > 0.5 {
                button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: y))
            }
        }
    }

    private func updateFullScreen() {
        guard let window, let workspace else { return }
        let isFullScreen = window.styleMask.contains(.fullScreen)
        if workspace.isFullScreen != isFullScreen {
            workspace.isFullScreen = isFullScreen
        }
    }

    func apply(activate: Bool) {
        guard let window else { return }
        if window.title != title {
            window.title = title
        }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = IDEAppearance.NSToken.window
        if let closeGuard {
            MainActor.assumeIsolated {
                closeGuard.install(on: window)
            }
        }
        centerTrafficLights()
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
    /// SwiftUI's original delegate. Weak so a closed window can release it.
    /// `nonisolated(unsafe)` because `responds(to:)` and `forwardingTarget(for:)` are nonisolated
    /// `NSObject` hooks; AppKit calls them on the main thread, where `install(on:)` writes this.
    private nonisolated(unsafe) weak var upstream: NSWindowDelegate?

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

    // This object replaces the window's own delegate (SwiftUI's), and SwiftUI learns through that
    // delegate that a window closed, resized, changed screen and so on. Every message this class
    // does not handle goes to the original delegate; without that SwiftUI never hears the window
    // closed and keeps its scene, hosting view and workspace alive for the rest of the run.
    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) {
            return true
        }
        guard let upstream else { return false }
        return upstream.responds(to: aSelector)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let upstream, upstream.responds(to: aSelector) {
            return upstream
        }
        return super.forwardingTarget(for: aSelector)
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
