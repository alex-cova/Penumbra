import DiagramKit
import SwiftUI

/// A diagram tab's content: a toolbar over the canvas, with a status line for truncation and errors.
struct IDEDiagramRootView: View {
    @Bindable var session: IDEDiagramSession
    var window: () -> NSWindow? = { nil }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(IDEAppearance.ColorToken.border)
            ZStack {
                if !session.document.nodes.isEmpty {
                    IDEDiagramCanvasView(session: session)
                }
                overlay
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let notice = session.notice {
                noticeBar(notice)
            }
        }
        .background(IDEAppearance.ColorToken.editor)
        .preferredColorScheme(IDEAppearance.preferredColorScheme)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            Image(systemName: session.request.symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(IDEAppearance.ColorToken.accent)
            Text(session.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .lineLimit(1)
                .truncationMode(.middle)
            if !session.summary.isEmpty {
                Text(session.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: IDEAppearance.Spacing.sm)
            layoutMenu
            routingMenu
            optionsMenu
            Button {
                session.refresh()
            } label: {
                Label("Reload Diagram", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .disabled(session.isLoading)
            .help("Reload diagram")
            exportMenu
            DiagramZoomControls(
                zoomPercent: Int((session.host.viewport.zoom * 100).rounded()),
                canFrameContent: !session.document.nodes.isEmpty,
                onZoomOut: { session.host.zoomOut() },
                onZoomIn: { session.host.zoomIn() },
                onOneToOne: { session.host.resetZoomOneToOne() },
                onCenter: { session.host.centerViewport() },
                onFit: { session.fit() }
            )
        }
        .padding(.horizontal, IDEAppearance.Spacing.md)
        .frame(height: 32)
        .background(IDEAppearance.ColorToken.tabBar)
    }

    private var layoutMenu: some View {
        Menu {
            Picker("Layout", selection: $session.settings.layout) {
                ForEach(IDEDiagramLayoutKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Layout", systemImage: "rectangle.3.group")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Arrange the diagram")
        .disabled(session.document.nodes.isEmpty)
    }

    private var routingMenu: some View {
        Menu {
            Picker("Edge Routing", selection: $session.settings.routing) {
                ForEach(EdgeRoutingStyle.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Edge Routing", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Edge routing")
    }

    @ViewBuilder
    private var optionsMenu: some View {
        if session.request.isClassDiagram {
            Menu {
                Toggle("Members", isOn: $session.settings.showMembers)
                Toggle("Private Members", isOn: $session.settings.showPrivateMembers)
                    .disabled(!session.settings.showMembers)
                Toggle("External Types", isOn: $session.settings.showExternalTypes)
                Divider()
                Picker("Neighbours", selection: $session.settings.neighbourDepth) {
                    Text("Only Selection").tag(0)
                    Text("1 Level").tag(1)
                    Text("2 Levels").tag(2)
                }
                .pickerStyle(.inline)
            } label: {
                Label("Options", systemImage: "slider.horizontal.3").labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("What the diagram shows")
        } else if let configuration = session.libraryConfiguration {
            Menu {
                Picker("Configuration", selection: Binding(
                    get: { configuration },
                    set: { session.setLibraryConfiguration($0) }
                )) {
                    ForEach(IDEDiagramSettings.libraryConfigurations, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(configuration, systemImage: "slider.horizontal.3")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("The Gradle configuration to resolve")
        }
    }

    private var exportMenu: some View {
        Menu {
            ForEach(IDEDiagramExportFormat.allCases, id: \.self) { format in
                Button(format.title) { IDEDiagramExporter.export(session, as: format, window: window()) }
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up").labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Export the diagram")
        .disabled(session.document.nodes.isEmpty)
    }

    // MARK: - Overlays

    @ViewBuilder
    private var overlay: some View {
        switch session.state {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .padding(IDEAppearance.Spacing.md)
                .background(IDEAppearance.ColorToken.panel.opacity(0.9), in: .rect(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).stroke(IDEAppearance.ColorToken.panelBorder) }
        case .ready:
            EmptyView()
        case let .empty(message):
            messageView(symbol: "rectangle.3.group", title: "Nothing to show", text: message, showsRetry: true)
        case let .failed(message):
            messageView(symbol: "exclamationmark.triangle", title: "Couldn’t build the diagram", text: message, showsRetry: true)
        }
    }

    private func messageView(symbol: String, title: String, text: String, showsRetry: Bool) -> some View {
        VStack(spacing: IDEAppearance.Spacing.sm) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .textSelection(.enabled)
            }
            if showsRetry {
                Button("Try Again") { session.refresh() }
                    .controlSize(.small)
            }
        }
        .padding(IDEAppearance.Spacing.xl)
    }

    private func noticeBar(_ text: String) -> some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            Image(systemName: "info.circle")
                .foregroundStyle(IDEAppearance.ColorToken.gitModified)
            Text(text)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .foregroundStyle(IDEAppearance.ColorToken.muted)
        .padding(.horizontal, IDEAppearance.Spacing.md)
        .padding(.vertical, 6)
        .background(IDEAppearance.ColorToken.tabBar)
        .overlay(alignment: .top) { Divider().overlay(IDEAppearance.ColorToken.border) }
    }
}
