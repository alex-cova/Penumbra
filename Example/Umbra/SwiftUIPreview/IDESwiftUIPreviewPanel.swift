import SwiftIntelligence
import SwiftUI

/// The canvas beside the editor: the frame the preview host rendered, the preview picker, light and
/// dark, refresh and close. The session does the work; this only shows it and reports the size and
/// the clicks.
struct IDESwiftUIPreviewPanel: View {
    let session: IDESwiftUIPreviewSession
    let onClose: () -> Void
    @State private var isLogVisible = false
    /// The magnification of a pinch in progress; the zoom is set when it ends.
    @State private var pinch: CGFloat = 1

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

            environmentMenu

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

    /// Text size, language, layout direction and window size: what the preview is shown under.
    private var environmentMenu: some View {
        Menu {
            Picker("Text Size", selection: Binding(get: { session.textSize }, set: { session.setTextSize($0) })) {
                ForEach(IDESwiftUIPreviewSession.TextSize.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Language", selection: Binding(get: { session.language }, set: { session.setLanguage($0) })) {
                ForEach(IDESwiftUIPreviewSession.Language.all) { Text($0.title).tag($0) }
            }
            Toggle("Right to Left", isOn: Binding(get: { session.isRightToLeft }, set: { session.setRightToLeft($0) }))
            if session.isSimulatorPreview {
                // The simulator's window is the device's: the choice is which device, from the runtime's own list.
                Picker("Device", selection: Binding(
                    get: { session.simulatorDeviceTypeID ?? "" }, set: { session.setSimulatorDeviceType($0) }
                )) {
                    ForEach(session.simulatorDeviceTypes, id: \.identifier) { Text($0.name).tag($0.identifier) }
                }
                if session.frameDevice != nil {
                    Toggle("Device Frame", isOn: Binding(get: { session.showsDeviceFrame }, set: { session.setShowsDeviceFrame($0) }))
                }
            } else {
                Picker("Size", selection: Binding(get: { session.sizePreset }, set: { session.setSizePreset($0) })) {
                    ForEach(IDESwiftUIPreviewSession.SizePreset.layouts) { Text($0.title).tag($0) }
                    Section("iPhone") {
                        ForEach(IDESwiftUIPreviewSession.SizePreset.devices) { Text($0.title).tag($0) }
                    }
                    Section("Window") {
                        ForEach(IDESwiftUIPreviewSession.SizePreset.windows) { Text($0.title).tag($0) }
                    }
                }
                if session.sizePreset.device != nil {
                    Toggle("Device Frame", isOn: Binding(get: { session.showsDeviceFrame }, set: { session.setShowsDeviceFrame($0) }))
                }
                if session.sizePreset.device != nil || session.dropsPreviewFrame || session.keepsPreviewFrame {
                    Toggle("Keep the Preview's Own Frame", isOn: Binding(
                        get: { session.keepsPreviewFrame }, set: { session.setKeepsPreviewFrame($0) }
                    ))
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Text size, language, layout direction, size and device")
    }

    private var title: String {
        guard session.blocks.indices.contains(session.selectedIndex) else { return session.fileName ?? "Preview" }
        return session.blocks[session.selectedIndex].displayName
    }

    // MARK: Canvas

    private var canvas: some View {
        GeometryReader { proxy in
            let scale = displayScale(in: proxy.size)
            ZStack {
                ScrollView([.horizontal, .vertical]) {
                    if let image = session.frame {
                        framed(image, scale: scale)
                            .scaleEffect(pinch)
                            // Smaller than the panel: centred; larger: scrolls.
                            .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
                            .opacity(session.phase.isWorking ? 0.55 : 1)
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                statusOverlay
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .overlay(alignment: .bottomTrailing) {
                if session.frame != nil { zoomControls(scale: scale) }
            }
            .overlay(alignment: .bottomLeading) {
                if let ignored = session.ignoredFrame, session.dropsPreviewFrame { ignoredFrameNote(ignored) }
            }
            .gesture(
                MagnifyGesture()
                    .onChanged { pinch = $0.magnification }
                    .onEnded { value in
                        pinch = 1
                        session.setZoom(.scale(IDESwiftUIPreviewZoom.clamped(scale * value.magnification)))
                    }
            )
            .onAppear { session.setViewport(proxy.size) }
            .onChange(of: proxy.size) { _, size in session.setViewport(size) }
        }
    }

    /// How many panel points one point of the frame takes (zoom, or what fits).
    private func displayScale(in panel: CGSize) -> Double {
        let extra = session.frameDevice.map {
            CGSize(width: $0.bezelSide * 2, height: $0.bezelTop + $0.bezelBottom)
        } ?? .zero
        return IDESwiftUIPreviewLayout.displayScale(
            zoom: session.zoom, fillsCanvas: session.fillsCanvas,
            frameSize: session.frameSize, extra: extra, panel: panel
        )
    }

    /// The frame at `scale`, with a device's bezel around it when one is chosen.
    @ViewBuilder
    private func framed(_ image: NSImage, scale: Double) -> some View {
        let screen = Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: session.frameSize.width * scale, height: session.frameSize.height * scale)
            .overlay { IDESwiftUIPreviewInput(session: session) }
        if let device = session.frameDevice {
            IDESwiftUIPreviewDeviceFrame(device: device, scale: scale) { screen }
        } else {
            screen
        }
    }

    /// Says why the preview takes the chosen size and not the one its own code asks for.
    private func ignoredFrameNote(_ frame: String) -> some View {
        Button {
            session.setKeepsPreviewFrame(true)
        } label: {
            Label("Ignoring \(frame)", systemImage: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 10))
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .padding(10)
        .help("The preview sets its own size. Click to keep it instead of the size chosen.")
    }

    /// Xcode's canvas controls: zoom out, the level (a menu of steps and Fit), zoom in.
    private func zoomControls(scale: Double) -> some View {
        HStack(spacing: 2) {
            Button {
                session.setZoom(.scale(IDESwiftUIPreviewZoom.previous(before: scale)))
            } label: {
                Image(systemName: "minus").frame(width: 22, height: 22)
            }
            .disabled(scale <= IDESwiftUIPreviewZoom.range.lowerBound + 0.001)
            .help("Zoom out")

            Menu {
                Button {
                    session.setZoom(.fit)
                } label: {
                    Label("Fit", systemImage: session.zoom == .fit ? "checkmark" : "")
                }
                Divider()
                ForEach(IDESwiftUIPreviewZoom.steps, id: \.self) { step in
                    Button {
                        session.setZoom(.scale(step))
                    } label: {
                        Label(IDESwiftUIPreviewZoom.percentTitle(step),
                              systemImage: session.zoom.factor == step ? "checkmark" : "")
                    }
                }
            } label: {
                Text(IDESwiftUIPreviewZoom.percentTitle(scale))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .frame(minWidth: 40)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Zoom level")

            Button {
                session.setZoom(.scale(IDESwiftUIPreviewZoom.next(after: scale)))
            } label: {
                Image(systemName: "plus").frame(width: 22, height: 22)
            }
            .disabled(scale >= IDESwiftUIPreviewZoom.range.upperBound - 0.001)
            .help("Zoom in")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(.quaternary) }
        .padding(10)
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
