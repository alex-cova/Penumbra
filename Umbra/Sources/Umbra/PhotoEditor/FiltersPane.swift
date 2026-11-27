import SwiftUI

/// Presets module: the built-in looks over live thumbnails of the open photo, plus the user's
/// saved looks. The reference kept saved looks in SwiftData; Umbra has no SwiftData stack, so
/// they live in `PhotoLookStore` (JSON) and the pane owns the in-memory list.
struct FiltersPane: View {
    @Bindable var session: PhotoEditorSession

    @AppStorage("photoEditor.module.presets") private var isExpanded = false
    @State private var showSaveAlert = false
    @State private var newLookName = ""
    @State private var showRenameAlert = false
    @State private var renaming: PhotoLookStore.Record?
    @State private var renameText = ""
    /// Decoded look recipes, refreshed when the saved set changes — decoding per row in `body`
    /// was the pane's worst re-render cost.
    @State private var decodedLooks: [UUID: EditAdjustment] = [:]
    @State private var savedLooks: [PhotoLookStore.Record] = PhotoLookStore.load()

    private let lookColumns = [
        GridItem(.flexible(), spacing: PhotoStudio.Spacing.sm),
        GridItem(.flexible(), spacing: PhotoStudio.Spacing.sm),
    ]

    var body: some View {
        PhotoInspectorModule(
            title: "Presets",
            isExpanded: $isExpanded,
            trailing: {
                Button("Save Look", systemImage: "plus", action: beginSaveLook)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
                    .foregroundStyle(PhotoStudio.Photo.label)
                    .disabled(session.adjustments.lookRecipe.isIdentity)
                    .help("Save Look")
            }
        ) {
            LazyVGrid(columns: lookColumns, spacing: PhotoStudio.Spacing.sm) {
                ForEach(PhotoPreset.allCases) { preset in
                    PhotoLookCard(
                        preset: preset,
                        thumbnail: session.presetThumbnails[preset],
                        isActive: session.adjustments.preset == preset,
                        action: { applyBuiltIn(preset) }
                    )
                }
            }

            if !savedLooks.isEmpty {
                Divider().overlay(PhotoStudio.Photo.hairline)
                LazyVStack(alignment: .leading, spacing: PhotoStudio.Spacing.xs) {
                    ForEach(savedLooks) { preset in
                        PhotoSavedLookRow(
                            name: preset.name,
                            isActive: isApplied(preset),
                            action: { apply(preset) },
                            onRename: { beginRename(preset) },
                            onDelete: { delete(preset) }
                        )
                    }
                }
            }
        }
        .task(id: looksDigest) { rebuildDecodedLooks() }
        .alert("Save Look", isPresented: $showSaveAlert) {
            TextField("Name", text: $newLookName)
            Button("Save", action: saveCurrentLook)
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Look", isPresented: $showRenameAlert) {
            TextField("Name", text: $renameText)
            Button("Save", action: commitRename)
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private var looksDigest: String {
        savedLooks.map { "\($0.id.uuidString):\($0.recipeJSON.count)" }.joined(separator: "|")
    }

    private func rebuildDecodedLooks() {
        var next: [UUID: EditAdjustment] = [:]
        for preset in savedLooks {
            next[preset.id] = PhotoLookStore.adjustments(for: preset)
        }
        decodedLooks = next
    }

    private func applyBuiltIn(_ preset: PhotoPreset) {
        session.mutate { $0.preset = preset }
        session.commit()
    }

    private func beginSaveLook() {
        newLookName = ""
        showSaveAlert = true
    }

    private func isApplied(_ preset: PhotoLookStore.Record) -> Bool {
        guard let look = decodedLooks[preset.id] else { return false }
        return session.adjustments.lookRecipe == look.lookRecipe
    }

    private func apply(_ preset: PhotoLookStore.Record) {
        guard let look = decodedLooks[preset.id] ?? PhotoLookStore.adjustments(for: preset) else {
            return
        }
        session.applyLook(look)
    }

    private func beginRename(_ preset: PhotoLookStore.Record) {
        renameText = preset.name
        renaming = preset
        showRenameAlert = true
    }

    private func delete(_ preset: PhotoLookStore.Record) {
        savedLooks = PhotoLookStore.remove(id: preset.id)
    }

    private func saveCurrentLook() {
        savedLooks = PhotoLookStore.add(name: newLookName, adjustments: session.adjustments)
    }

    private func commitRename() {
        guard let renaming else { return }
        savedLooks = PhotoLookStore.rename(id: renaming.id, to: renameText)
        self.renaming = nil
    }
}

private struct PhotoLookCard: View {
    let preset: PhotoPreset
    let thumbnail: CGImage?
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: PhotoStudio.Spacing.xs) {
                Group {
                    if let thumbnail {
                        Image(decorative: thumbnail, scale: 1, orientation: .up)
                            .resizable()
                            .scaledToFill()
                    } else {
                        PhotoStudio.Photo.panelDeep
                            .overlay { ProgressView().controlSize(.mini) }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 72)
                .clipShape(.rect(cornerRadius: PhotoStudio.Radius.xs))
                .overlay {
                    RoundedRectangle(cornerRadius: PhotoStudio.Radius.xs)
                        .strokeBorder(
                            isActive ? PhotoStudio.accent : PhotoStudio.Photo.hairline,
                            lineWidth: isActive ? 2 : 1
                        )
                }

                Text(preset.displayName)
                    .font(PhotoStudio.Typography.caption)
                    .foregroundStyle(isActive ? PhotoStudio.Photo.value : PhotoStudio.Photo.label)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .photoAnimation(PhotoStudio.Motion.standard, value: isActive)
    }
}

private struct PhotoSavedLookRow: View {
    let name: String
    let isActive: Bool
    let action: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: "paintpalette")
                    .foregroundStyle(isActive ? PhotoStudio.accent : PhotoStudio.Photo.label)
                Text(name)
                    .lineLimit(1)
                    .foregroundStyle(isActive ? PhotoStudio.Photo.value : PhotoStudio.Photo.label)
                Spacer()
            }
            .padding(.vertical, PhotoStudio.Spacing.xs)
            .padding(.horizontal, PhotoStudio.Spacing.xs)
            .background(
                isActive ? PhotoStudio.accent.opacity(0.16) : Color.clear,
                in: .rect(cornerRadius: PhotoStudio.Radius.xs)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityLabel(name)
        .contextMenu {
            Button("Rename…", systemImage: "pencil", action: onRename)
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }
}
