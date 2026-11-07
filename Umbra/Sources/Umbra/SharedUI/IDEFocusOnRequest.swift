import SwiftUI

/// Sets a `FocusState` when a workspace focus request lands.
///
/// The request is identified by `requestID` so a second request still fires after the first was
/// consumed. `consume` returns whether this view should take the keyboard (and clears the pending
/// request); a remount from a mouse click, with nothing pending, leaves focus where it is. It is
/// asked once when the view appears (a shortcut that switched tabs made the request before the new
/// tab's view existed) and once per new `requestID`.
struct IDEFocusRequestTaker: ViewModifier {
    let requestID: UInt64
    let consume: () -> Bool
    let takeFocus: () -> Void

    init(requestID: UInt64, consume: @escaping () -> Bool, takeFocus: @escaping () -> Void) {
        self.requestID = requestID
        self.consume = consume
        self.takeFocus = takeFocus
    }

    init(requestID: UInt64, consume: @escaping () -> Bool, focus: FocusState<Bool>.Binding) {
        self.init(requestID: requestID, consume: consume, takeFocus: { focus.wrappedValue = true })
    }

    func body(content: Content) -> some View {
        content
            .onAppear { takeFocusIfRequested() }
            .onChange(of: requestID) { _, _ in takeFocusIfRequested() }
    }

    private func takeFocusIfRequested() {
        guard consume() else { return }
        takeFocus()
    }
}

/// Moves the keyboard onto a `.focusable()` view when a workspace focus request lands, using a
/// focus state of its own.
struct IDEFocusOnRequest: ViewModifier {
    let requestID: UInt64
    let consume: () -> Bool
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            .modifier(IDEFocusRequestTaker(requestID: requestID, consume: consume, focus: $isFocused))
    }
}

/// A sidebar tab's view that takes the keyboard when its tool-window shortcut shows the tab. A
/// click on the tab bar makes no request, so typing in the editor is not interrupted.
private struct IDESidebarFocus: ViewModifier {
    @Environment(IDEWorkspace.self) private var workspace
    let tab: IDESidebarTab
    var focus: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        content.modifier(IDEFocusRequestTaker(
            requestID: workspace.sidebarFocusRequestID,
            consume: { workspace.consumeSidebarFocusIfNeeded(for: tab) },
            focus: focus
        ))
    }
}

/// The same for the project sidebar (Gradle, Maven, SwiftPM, npm, Xcode), which has one slot.
private struct IDEProjectSidebarFocus: ViewModifier {
    @Environment(IDEWorkspace.self) private var workspace
    let takeFocus: () -> Void

    func body(content: Content) -> some View {
        content.modifier(IDEFocusRequestTaker(
            requestID: workspace.projectSidebarFocusRequestID,
            consume: { workspace.consumeProjectSidebarFocusIfNeeded() },
            takeFocus: takeFocus
        ))
    }
}

extension View {
    func ideFocus(onRequest requestID: UInt64, consume: @escaping () -> Bool) -> some View {
        modifier(IDEFocusOnRequest(requestID: requestID, consume: consume))
    }

    /// Sets `focus` when the shortcut for sidebar `tab` shows it. Needs `IDEWorkspace` in the environment.
    func ideSidebarFocus(_ tab: IDESidebarTab, on focus: FocusState<Bool>.Binding) -> some View {
        modifier(IDESidebarFocus(tab: tab, focus: focus))
    }

    /// Sets `focus` when the project sidebar's shortcut shows it. Needs `IDEWorkspace` in the environment.
    func ideProjectSidebarFocus(on focus: FocusState<Bool>.Binding) -> some View {
        modifier(IDEProjectSidebarFocus(takeFocus: { focus.wrappedValue = true }))
    }

    /// Runs `takeFocus` when the project sidebar's shortcut shows it, for a panel that decides
    /// which of several fields should have the keyboard.
    func ideProjectSidebarFocus(perform takeFocus: @escaping () -> Void) -> some View {
        modifier(IDEProjectSidebarFocus(takeFocus: takeFocus))
    }
}
