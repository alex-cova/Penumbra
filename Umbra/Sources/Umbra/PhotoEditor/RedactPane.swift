import SwiftUI

/// "Redact" module: enter the canvas draw mode and tune each pixelate / blur / block-out region.
struct RedactPane: View {
    @Bindable var session: PhotoEditorSession
    @AppStorage("photoEditor.module.redact") private var isExpanded = false

    private var regions: [RedactionRegion] { session.adjustments.redactions }

    var body: some View {
        PhotoInspectorModule(
            title: "Redact",
            isExpanded: $isExpanded,
            trailing: {
                PhotoInspectorResetButton(isEnabled: !regions.isEmpty, action: clearAll)
            }
        ) {
            Text("Hide sensitive areas before export. Boxes are non-destructive and travel with the recipe.")
                .font(PhotoStudio.Typography.caption2)
                .foregroundStyle(PhotoStudio.Photo.label)
                .fixedSize(horizontal: false, vertical: true)

            Button(session.isRedacting ? "Done Drawing" : "Draw Regions", systemImage: session.isRedacting ? "checkmark" : "rectangle.dashed") {
                session.setRedacting(!session.isRedacting)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(session.isRedacting ? PhotoStudio.accent : nil)

            if regions.isEmpty {
                Text("No regions yet.")
                    .font(PhotoStudio.Typography.caption)
                    .foregroundStyle(PhotoStudio.Photo.label.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(regions.enumerated()), id: \.element.id) { index, region in
                    regionRow(index: index, region: region)
                }
            }
        }
        .onChange(of: session.isRedacting) {
            if session.isRedacting { isExpanded = true }
        }
    }

    @ViewBuilder
    private func regionRow(index: Int, region: RedactionRegion) -> some View {
        VStack(alignment: .leading, spacing: PhotoStudio.Spacing.xs) {
            HStack {
                Text("Region \(index + 1)")
                    .font(PhotoStudio.Typography.captionEmphasis)
                    .foregroundStyle(
                        session.selectedRedactionID == region.id
                            ? PhotoStudio.accent
                            : PhotoStudio.Photo.value
                    )
                Spacer(minLength: 0)
                Button("Remove", systemImage: "trash") {
                    session.removeRedaction(id: region.id)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .controlSize(.mini)
                .foregroundStyle(PhotoStudio.Photo.label)
            }

            Picker("Style", selection: Binding(
                get: { region.style },
                set: { session.setRedactionStyle(id: region.id, $0) }
            )) {
                ForEach(RedactionStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if region.style != .solid {
                PhotoAdjustmentSlider(
                    value: region.strength,
                    parameterName: "Strength",
                    lowerBound: 0,
                    upperBound: 100,
                    detent: nil,
                    onChanged: { session.setRedactionStrength(id: region.id, $0) },
                    onEnded: { session.commit() }
                )
            }
        }
        .padding(.vertical, PhotoStudio.Spacing.xs)
        .contentShape(.rect)
        .onTapGesture { session.selectedRedactionID = region.id }
    }

    private func clearAll() {
        for region in regions {
            session.removeRedaction(id: region.id)
        }
    }
}
