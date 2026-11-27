import SwiftUI

/// The photo editor as embedded in an Umbra image tab: canvas plus the Develop inspector, with a
/// header carrying the file facts, the zoom cluster, compare/sample/clipping/crop/redact tools,
/// and Save / Export / Done.
///
/// Ported from the reference `PhotoEditorWorkspace`. Differences from the reference:
/// - No drop well, import, or replace: the editor opens on the tab's file.
/// - No `Close` with a discard confirm: leaving edit mode keeps the autosaved recipe, so Done
///   never loses work (Reset clears the recipe explicitly).
/// - `Save` writes the rendered full-resolution image back to the tab's file in its own format
///   (disabled for RAW, which has no round-trippable target); `Export` saves a copy elsewhere.
/// - No ⌘Z / ⌘⇧Z / ⌘O / ⌘-digit shortcuts: those belong to Umbra's window and menu key
///   equivalents win over canvas `.onKeyPress`.
struct PhotoEditorWorkspace: View {
    @Bindable var session: PhotoEditorSession
    var canSave: Bool
    var onSave: () -> Void
    var onExport: () -> Void
    var onDone: () -> Void

    var body: some View {
        SplitPanes(
            minPrimary: 220,
            minSecondary: 260,
            maxSecondary: 440,
            idealSecondary: 300,
            storageKey: "photoEditor.inspector",
            priority: .secondary
        ) {
            VStack(alignment: .leading, spacing: PhotoStudio.Spacing.sm) {
                PhotoEditorCanvasHeader(
                    session: session,
                    canSave: canSave,
                    onSave: onSave,
                    onExport: onExport,
                    onDone: onDone
                )
                PhotoCanvasView(session: session)
                    .clipShape(.rect(cornerRadius: PhotoStudio.Radius.md))
                    .overlay {
                        RoundedRectangle(cornerRadius: PhotoStudio.Radius.md)
                            .strokeBorder(PhotoStudio.Photo.hairline, lineWidth: 1)
                    }
            }
        } secondary: {
            PhotoEditorInspector(session: session)
                .padding(PhotoStudio.Spacing.sm)
        }
        .background(PhotoStudio.Photo.panel)
    }
}

private struct PhotoEditorCanvasHeader: View {
    @Bindable var session: PhotoEditorSession
    var canSave: Bool
    var onSave: () -> Void
    var onExport: () -> Void
    var onDone: () -> Void

    var body: some View {
        HStack(spacing: PhotoStudio.Spacing.sm) {
            ScrollView(.horizontal) {
                HStack(spacing: PhotoStudio.Spacing.sm) {
                    if let name = session.sourceFileName {
                        Label {
                            Text(name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } icon: {
                            Image(systemName: "photo")
                        }
                        .font(PhotoStudio.Typography.caption)
                        .foregroundStyle(PhotoStudio.Photo.label)
                        .frame(maxWidth: 160, alignment: .leading)
                    }
                    if session.sourcePixelSize.width > 0 {
                        Label(
                            pixelSizeText,
                            systemImage: "aspectratio"
                        )
                        .font(PhotoStudio.Typography.caption)
                        .foregroundStyle(PhotoStudio.Photo.label)
                    }
                    if session.isRAW {
                        Label("RAW", systemImage: "camera.aperture")
                            .font(PhotoStudio.Typography.caption)
                            .foregroundStyle(PhotoStudio.Photo.label)
                    }

                    PhotoZoomControls(session: session)
                    PhotoGridMenu()

                HStack(spacing: PhotoStudio.Spacing.xs) {
                    Button("Undo", systemImage: "arrow.uturn.backward", action: session.undo)
                        .disabled(!session.canUndo)
                        .help("Undo")
                    Button("Redo", systemImage: "arrow.uturn.forward", action: session.redo)
                        .disabled(!session.canRedo)
                        .help("Redo")
                    PhotoEditorCompareButton(session: session)
                    Button("Split Compare", systemImage: session.compareMode.symbol) {
                        session.cycleCompareMode()
                    }
                    .foregroundStyle(session.compareMode == .off ? .secondary : PhotoStudio.accent)
                    .help("Before / after: \(String(localized: session.compareMode.displayName))")
                    .accessibilityAddTraits(session.compareMode == .off ? [] : .isSelected)
                    Button("Sample Color", systemImage: "eyedropper") {
                        session.isSampling.toggle()
                    }
                    .foregroundStyle(session.isSampling ? PhotoStudio.accent : .secondary)
                    .help("Colour sampler & loupe (or hold ⌥)")
                    .accessibilityAddTraits(session.isSampling ? .isSelected : [])
                    Button("Clipping Warnings", systemImage: "exclamationmark.triangle") {
                        session.toggleClippingWarnings()
                    }
                    .foregroundStyle(session.showClippingWarnings ? PhotoStudio.accent : .secondary)
                    .help("Highlight blown highlights (red) and crushed shadows (blue)")
                    .accessibilityAddTraits(session.showClippingWarnings ? .isSelected : [])
                    Button("Crop", systemImage: "crop") {
                        session.setCropping(!session.isCropping)
                    }
                    .foregroundStyle(session.isCropping ? PhotoStudio.accent : .secondary)
                    .keyboardShortcut("r", modifiers: [])
                    .help("Crop & straighten (R)")
                    .accessibilityAddTraits(session.isCropping ? .isSelected : [])
                    Button("Redact", systemImage: "eye.slash") {
                        session.setRedacting(!session.isRedacting)
                    }
                    .foregroundStyle(session.isRedacting ? PhotoStudio.accent : .secondary)
                    .help("Pixelate or blur regions")
                    .accessibilityAddTraits(session.isRedacting ? .isSelected : [])
                    PhotoEditorResetButton(session: session)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity)

            HStack(spacing: PhotoStudio.Spacing.xs) {
                Button("Save", systemImage: "checkmark.circle", action: onSave)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!canSave || session.adjustments.isIdentity)
                    .help(
                        session.isRAW
                            ? "RAW files cannot be saved back; use Export"
                            : "Save the edited image back to this file"
                    )

                Button("Export", systemImage: "square.and.arrow.up", action: onExport)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Export a copy")

                Button("Done", systemImage: "xmark.circle", action: onDone)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Leave the photo editor (edits autosave)")
            }
            .fixedSize()
        }
        .padding(.vertical, PhotoStudio.Spacing.xs)
    }

    private var pixelSizeText: String {
        "\(Int(session.sourcePixelSize.width)) × \(Int(session.sourcePixelSize.height))"
    }
}

/// Compact zoom / framing cluster for the photo canvas.
struct PhotoZoomControls: View {
    @Bindable var session: PhotoEditorSession

    var body: some View {
        HStack(spacing: 2) {
            Button("Zoom Out", systemImage: "minus.magnifyingglass") {
                session.zoomViewportStep(zoomingIn: false)
            }
            .help("Zoom out")

            Button("Zoom In", systemImage: "plus.magnifyingglass") {
                session.zoomViewportStep(zoomingIn: true)
            }
            .help("Zoom in")

            Button {
                session.frame(.actualSize)
            } label: {
                Text("1:1")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .frame(minWidth: 26)
            }
            .help("Actual size, 100%")
            .accessibilityLabel("Actual size 100 percent")

            Button("Fit", systemImage: "arrow.up.left.and.arrow.down.right") {
                session.frame(.fit)
            }
            .help("Fit in window")

            Button("Fill", systemImage: "arrow.down.right.and.arrow.up.left") {
                session.frame(.fill)
            }
            .help("Fill window")

            Text("\(session.viewport.percent)%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }
}

/// Composition-overlay picker, backed by the same `@AppStorage` the canvas reads.
private struct PhotoGridMenu: View {
    @AppStorage("photoEditor.gridStyle") private var gridStyleRaw = PhotoGridStyle.off.rawValue

    private var style: PhotoGridStyle {
        PhotoGridStyle(rawValue: gridStyleRaw) ?? .off
    }

    var body: some View {
        Menu {
            Picker("Grid", selection: $gridStyleRaw) {
                ForEach(PhotoGridStyle.allCases) { option in
                    Label(option.displayName, systemImage: option.symbol).tag(option.rawValue)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label("Grid", systemImage: "grid")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(style == .off ? Color.secondary : PhotoStudio.accent)
        .help("Composition grid overlay")
        .accessibilityLabel("Grid overlay: \(String(localized: style.displayName))")
    }
}

/// Isolated so `session.adjustments.isIdentity` does not re-render the whole canvas header on
/// every slider tick.
private struct PhotoEditorResetButton: View {
    @Bindable var session: PhotoEditorSession

    var body: some View {
        Button("Reset", systemImage: "arrow.counterclockwise", action: session.reset)
            .disabled(session.adjustments.isIdentity)
            .help("Reset adjustments")
    }
}

private struct PhotoEditorCompareButton: View {
    @Bindable var session: PhotoEditorSession

    var body: some View {
        Button("Compare", systemImage: session.isComparing ? "eye.fill" : "eye") {}
            .foregroundStyle(session.isComparing ? PhotoStudio.accent : .secondary)
            .help("Hold to compare with the original")
            .accessibilityHint("Hold to compare with the original")
            .accessibilityAddTraits(session.isComparing ? .isSelected : [])
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !session.isComparing { session.beginCompare() }
                    }
                    .onEnded { _ in
                        session.endCompare()
                    }
            )
    }
}
