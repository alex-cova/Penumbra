import AppKit
import SwiftUI
import WebKit

/// An embedded browser beside the conversation, for the page the agent is building: the dev server it
/// started, or any address. Nothing loads until you enter an address or pick a server.
struct IDEAIBrowserTab: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        Group {
            if let model = workspace.aiBrowser {
                IDEAIBrowserContent(model: model)
            } else {
                Color.clear
            }
        }
        // The page is made when the tab first shows and lives until the window closes, so leaving the tab
        // or switching chats does not lose what was loaded.
        .onAppear { workspace.ensureAIBrowser() }
    }
}

private struct IDEAIBrowserContent: View {
    @Bindable var model: IDEAIBrowserModel
    @Environment(IDEWorkspace.self) private var workspace
    @State private var address = ""
    @FocusState private var isAddressFocused: Bool

    private var servers: [URL] { IDEAIBrowserAddress.localServers(in: workspace.agent.selected.entries) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if model.page.isLoading {
                ProgressView(value: model.page.estimatedProgress)
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
                    .tint(IDEAppearance.ColorToken.accent)
            } else {
                Color.clear.frame(height: 2)
            }
            if let rejection = model.rejection {
                Text(rejection)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.error)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, IDEAppearance.Spacing.sm)
                    .padding(.bottom, IDEAppearance.Spacing.xs)
            }
            if let activity = model.agentActivity { agentBanner(activity) }
            if model.isPicking { pickHint }
            if !model.annotations.isEmpty {
                IDEAIBrowserNotesBar(model: model) {
                    workspace.agent.selected.attachesBrowserNotes = true
                    workspace.agent.compose("Please go through my notes on the page and make the changes they ask for.", send: true)
                }
            }
            Divider().overlay(IDEAppearance.ColorToken.border)
            if model.hasStarted {
                ZStack {
                    WebView(model.page)
                    noteAnchors
                    if model.agentActivity != nil {
                        // The agent is driving: the page ignores the pointer, and the edge says whose hands are on it.
                        Color.clear.contentShape(Rectangle()).onTapGesture {}
                        Rectangle().strokeBorder(Color.purple, lineWidth: 3).allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                blankState
            }
        }
        .onChange(of: model.page.url) { _, url in
            // The field follows the page unless the user is typing in it.
            if !isAddressFocused, let url { address = url.absoluteString }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 2) {
            IDEAIBrowserButton(symbol: "chevron.left", help: "Back", isEnabled: model.canGoBack, action: model.goBack)
            IDEAIBrowserButton(symbol: "chevron.right", help: "Forward", isEnabled: model.canGoForward, action: model.goForward)
            if model.page.isLoading {
                IDEAIBrowserButton(symbol: "xmark", help: "Stop Loading", isEnabled: true, action: model.stop)
            } else {
                IDEAIBrowserButton(symbol: "arrow.clockwise", help: "Reload", isEnabled: model.hasStarted, action: model.reload)
            }
            TextField("Address, such as localhost:3000", text: $address)
                .textFieldStyle(.plain)
                .font(IDEAppearance.Typography.monoSmall)
                .focused($isAddressFocused)
                .onSubmit { model.go(to: address) }
                .padding(.horizontal, IDEAppearance.Spacing.sm)
                .frame(height: IDEAppearance.Spacing.iconButton)
                .background(
                    IDEAppearance.ColorToken.editor,
                    in: RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous)
                        .strokeBorder(isAddressFocused ? IDEAppearance.ColorToken.accent : IDEAppearance.ColorToken.border))
                .accessibilityLabel("Address")
            IDEAIBrowserButton(
                symbol: "cursorarrow.rays", help: model.isPicking ? "Stop Selecting" : "Select an Element to Add a Note",
                isEnabled: model.hasStarted, isActive: model.isPicking
            ) { model.setPicking(!model.isPicking) }
            if !servers.isEmpty {
                Menu {
                    ForEach(servers, id: \.self) { url in
                        Button(url.absoluteString) { open(url) }
                    }
                } label: {
                    Image(systemName: "server.rack")
                        .font(.system(size: IDEAppearance.IconSize.toolbarGlyph, weight: .medium))
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .frame(width: IDEAppearance.Spacing.iconButton, height: IDEAppearance.Spacing.iconButton)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Local servers this chat started")
                .accessibilityLabel("Local servers")
            }
            IDEAIBrowserButton(
                symbol: "safari", help: "Open in Default Browser", isEnabled: model.page.url != nil
            ) {
                if let url = model.page.url { NSWorkspace.shared.open(url) }
            }
        }
        .padding(.horizontal, IDEAppearance.Spacing.xs)
        .padding(.vertical, IDEAppearance.Spacing.xs)
    }

    private func open(_ url: URL) {
        address = url.absoluteString
        model.open(url)
    }

    // MARK: - The agent at work

    private func agentBanner(_ activity: String) -> some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Image(systemName: "sparkles").foregroundStyle(Color.purple)
            Text("Agent is controlling this page · \(activity)…")
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button("Stop") { workspace.agent.stop() }
                .controlSize(.small)
                .help("Stop the agent")
        }
        .font(IDEAppearance.Typography.caption)
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, IDEAppearance.Spacing.xs)
        .background(Color.purple.opacity(0.18))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("The agent is controlling this page: \(activity)")
    }

    // MARK: - Selecting

    private var pickHint: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Image(systemName: "cursorarrow.rays").foregroundStyle(IDEAppearance.ColorToken.accent)
            Text("Click an element")
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button { model.climb(-1) } label: { Label("Parent", systemImage: "arrow.up") }
                .help("Select the element around the highlighted one (↑)")
            Button { model.climb(1) } label: { Label("Child", systemImage: "arrow.down") }
                .help("Select the element inside the highlighted one (↓)")
            Button("Done") { model.setPicking(false) }
                .help("Stop selecting (Esc)")
        }
        .font(IDEAppearance.Typography.caption)
        .controlSize(.small)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, IDEAppearance.Spacing.xs)
        .background(IDEAppearance.ColorToken.card)
    }

    /// Invisible views over the page at the picked element, so the note editor opens next to it.
    private var noteAnchors: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if let pick = model.pendingPick {
                    anchor(pick.viewRect, in: proxy.size)
                        .popover(
                            isPresented: Binding(
                                get: { model.pendingPick?.id == pick.id },
                                set: { if !$0, model.pendingPick?.id == pick.id { model.cancelPick() } }),
                            arrowEdge: .bottom
                        ) {
                            IDEAIBrowserNoteEditor(
                                title: pick.element.shortName, text: "", confirmTitle: "Add Note",
                                onConfirm: { model.commitPick(note: $0) }, onCancel: { model.cancelPick() })
                        }
                }
                if let edit = model.editingPin, let annotation = model.annotations.item(edit.id) {
                    anchor(edit.viewRect, in: proxy.size)
                        .popover(
                            isPresented: Binding(
                                get: { model.editingPin?.id == edit.id },
                                set: { if !$0 { model.editingPin = nil } }),
                            arrowEdge: .bottom
                        ) {
                            IDEAIBrowserNoteEditor(
                                title: "\(annotation.number)  \(annotation.element.shortName)", text: annotation.note,
                                confirmTitle: "Save", onConfirm: { model.saveEdit(edit.id, note: $0) },
                                onCancel: { model.editingPin = nil }, onDelete: { model.deleteAnnotation(edit.id) })
                        }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
    }

    private func anchor(_ rect: IDEAIElementInfo.Rect, in size: CGSize) -> some View {
        let x = min(max(rect.x, 0), max(size.width - 8, 0))
        let y = min(max(rect.y, 0), max(size.height - 8, 0))
        let width = max(min(rect.w, size.width - x), 8)
        let height = max(min(rect.h, size.height - y), 8)
        return Color.clear
            .frame(width: width, height: height)
            .offset(x: x, y: y)
    }

    // MARK: - Blank

    private var blankState: some View {
        VStack(spacing: IDEAppearance.Spacing.md) {
            Spacer(minLength: 0)
            Image(systemName: "globe")
                .font(.system(size: 22))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            Text("Open a page")
                .font(IDEAppearance.Typography.sectionHeader)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
            Text("Enter an address above to preview what the agent is building. Nothing loads until you do.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if !servers.isEmpty {
                VStack(spacing: IDEAppearance.Spacing.xs) {
                    Text("Local servers in this chat")
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                    ForEach(servers, id: \.self) { url in
                        Button(url.absoluteString) { open(url) }
                            .controlSize(.small)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(IDEAppearance.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct IDEAIBrowserButton: View {
    let symbol: String
    let help: String
    let isEnabled: Bool
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: IDEAppearance.IconSize.toolbarGlyph, weight: .medium))
                .foregroundStyle(
                    isActive ? IDEAppearance.ColorToken.accent
                        : isEnabled ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted.opacity(0.5))
                .frame(width: IDEAppearance.Spacing.iconButton, height: IDEAppearance.Spacing.iconButton)
                .background(
                    isActive ? IDEAppearance.ColorToken.card : Color.clear,
                    in: RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
