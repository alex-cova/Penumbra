import SwiftUI

struct CropPane: View {
    @Bindable var session: PhotoEditorSession
    @AppStorage("photoEditor.module.transform") private var isExpanded = false

    private let aspectColumns = Array(
        repeating: GridItem(.flexible(), spacing: PhotoStudio.Spacing.xs),
        count: 3
    )

    var body: some View {
        PhotoInspectorModule(
            title: "Transform",
            isExpanded: $isExpanded,
            trailing: {
                PhotoInspectorResetButton(isEnabled: !cropIsIdentity, action: resetCrop)
            }
        ) {
            HStack(spacing: PhotoStudio.Spacing.sm) {
                Button("Rotate Left", systemImage: "rotate.left", action: rotateLeft)
                    .help("Rotate left")
                    .frame(maxWidth: .infinity)
                Button("Rotate Right", systemImage: "rotate.right", action: rotateRight)
                    .help("Rotate right")
                    .frame(maxWidth: .infinity)
                Button(
                    "Flip Horizontal",
                    systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                    action: flipHorizontal
                )
                .help("Flip horizontal")
                .frame(maxWidth: .infinity)
                Button(
                    "Flip Vertical",
                    systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down",
                    action: flipVertical
                )
                .help("Flip vertical")
                .frame(maxWidth: .infinity)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .controlSize(.small)

            PhotoAdjustmentSlider(
                value: session.adjustments.straightenDegrees / 45 * 100,
                parameterName: "Straighten"
            ) { uiValue in
                session.mutate { $0.straightenDegrees = uiValue / 100 * 45 }
            } onEnded: {
                session.commit()
            }

            Text("Aspect Ratio")
                .font(PhotoStudio.Typography.caption)
                .foregroundStyle(PhotoStudio.Photo.label)
                .padding(.top, PhotoStudio.Spacing.xs)

            LazyVGrid(columns: aspectColumns, spacing: PhotoStudio.Spacing.xs) {
                ForEach(TransformEngine.AspectPreset.allCases) { preset in
                    PhotoInspectorChip(
                        title: preset.displayName,
                        isSelected: session.cropAspect == preset,
                        action: { applyAspect(preset) }
                    )
                }
            }

            HStack(spacing: PhotoStudio.Spacing.sm) {
                Button("Rotate Aspect", systemImage: "rectangle.portrait.rotate") {
                    session.swapCropOrientation()
                }
                .disabled(session.adjustments.crop == nil)
                .help("Swap the crop between landscape and portrait")
                .frame(maxWidth: .infinity)

                Button("Zoom to Crop", systemImage: "arrow.up.left.and.arrow.down.right.magnifyingglass") {
                    session.zoomViewportToCrop()
                }
                .help("Fit the crop area to the canvas")
                .frame(maxWidth: .infinity)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .onChange(of: session.isCropping) {
            if session.isCropping { isExpanded = true }
        }
    }

    private var cropIsIdentity: Bool {
        let adj = session.adjustments
        return adj.crop == nil
            && adj.rotationQuarterTurns == 0
            && adj.straightenDegrees == 0
            && !adj.flipHorizontal
            && !adj.flipVertical
    }

    private func rotateLeft() {
        session.mutate { $0.rotationQuarterTurns = ($0.rotationQuarterTurns + 3) % 4 }
        session.commit()
    }

    private func rotateRight() {
        session.mutate { $0.rotationQuarterTurns = ($0.rotationQuarterTurns + 1) % 4 }
        session.commit()
    }

    private func flipHorizontal() {
        session.mutate { $0.flipHorizontal.toggle() }
        session.commit()
    }

    private func flipVertical() {
        session.mutate { $0.flipVertical.toggle() }
        session.commit()
    }

    private func applyAspect(_ preset: TransformEngine.AspectPreset) {
        session.cropAspect = preset
        session.mutate { adj in
            if preset == .original {
                adj.crop = nil
            } else {
                adj.crop = TransformEngine.fittedRect(
                    ratio: preset.ratio,
                    in: CGRect(x: 0, y: 0, width: 1, height: 1)
                )
            }
        }
        session.commit()
    }

    private func resetCrop() {
        session.cropAspect = .original
        session.mutate { adj in
            adj.crop = nil
            adj.rotationQuarterTurns = 0
            adj.straightenDegrees = 0
            adj.flipHorizontal = false
            adj.flipVertical = false
        }
        session.commit()
    }
}
