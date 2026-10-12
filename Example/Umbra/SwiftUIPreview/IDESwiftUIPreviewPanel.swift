import SwiftIntelligence
import SwiftUI

/// The canvas beside the editor: the frame the preview host rendered, the preview picker, light and
/// dark, refresh and close. The session does the work; this only shows it and reports the size and
/// the clicks.
struct IDESwiftUIPreviewPanel: View {
    let session: IDESwiftUIPreviewSession
    let onClose: () -> Void
    @State private var isLogVisible = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            canvas
            if isLogVisible || isFailed {
                Divider()
                logView
            }
        }
        .background(IDEAppearance.ColorToken.workbench)
    }

    private var isFailed: Bool {
        if case .failed = session.phase { return true }
        return false
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(Array(session.blocks.enumerated()), id: \.offset) { index, block in
                    Button {
                        session.select(index)
                    } label: {
                        Label(block.displayName, systemImage: index == session.selectedIndex ? "checkmark" : "")
                    }
                }
            } label: {
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(session.blocks.count < 2)

            Spacer(minLength: 0)

            if session.phase.isWorking { ProgressView().controlSize(.small) }

            Picker("Appearance", selection: Binding(
                get: { session.colorScheme },
                set: { session.setColorScheme($0) }
            )) {
                Image(systemName: "sun.max").tag(IDESwiftUIPreviewSession.ColorScheme.light)
                Image(systemName: "moon").tag(IDESwiftUIPreviewSession.ColorScheme.dark)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 70)
            .help("Light or dark appearance")

            Button { isLogVisible.toggle() } label: { Image(systemName: "text.alignleft") }
                .buttonStyle(.borderless)
                .help("Show the build log")
            Button { session.rebuild() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Rebuild the preview")
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Close the preview")
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
    }

    private var title: String {
        guard session.blocks.indices.contains(session.selectedIndex) else { return session.fileName ?? "Preview" }
        return session.blocks[session.selectedIndex].displayName
    }

    // MARK: Canvas

    private var canvas: some View {
        GeometryReader { proxy in
            ZStack {
                ScrollView([.horizontal, .vertical]) {
                    if let image = session.frame {
                        Image(nsImage: image)
                            .resizable()
                            .frame(width: session.frameSize.width, height: session.frameSize.height)
                            .overlay { IDESwiftUIPreviewInput(session: session) }
                            .opacity(session.phase.isWorking ? 0.55 : 1)
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                statusOverlay
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .onAppear { session.setViewport(proxy.size) }
            .onChange(of: proxy.size) { _, size in session.setViewport(size) }
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch session.phase {
        case .idle:
            message("Press refresh to build the preview.", systemImage: "play.rectangle")
        case .building(let text):
            if session.frame == nil { message(text, systemImage: "hammer") }
        case .noPreviews:
            message("This file has no #Preview.", systemImage: "rectangle.dashed")
        case .unavailable(let text):
            message(text, systemImage: "doc")
        case .failed(let text):
            message(text, systemImage: "exclamationmark.triangle", tint: .orange)
        case .ready:
            EmptyView()
        }
    }

    private func message(_ text: String, systemImage: String, tint: Color = .secondary) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 22)).foregroundStyle(tint)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
        .padding(20)
    }

    // MARK: Log

    private var logView: some View {
        ScrollView {
            Text(session.log.suffix(120).joined(separator: "\n"))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .textSelection(.enabled)
        }
        .frame(height: 140)
    }
}
