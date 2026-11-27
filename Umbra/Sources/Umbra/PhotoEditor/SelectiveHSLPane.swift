import SwiftUI

struct SelectiveHSLPane: View {
    @Bindable var session: PhotoEditorSession
    @AppStorage("photoEditor.module.colormix") private var isExpanded = false

    private let bandColumns = Array(
        repeating: GridItem(.flexible(), spacing: PhotoStudio.Spacing.xs),
        count: 4
    )

    var body: some View {
        PhotoInspectorModule(
            title: "Color Mix",
            isExpanded: $isExpanded,
            trailing: {
                PhotoInspectorResetButton(
                    isEnabled: !session.adjustments.selectiveHSL.isIdentity,
                    action: resetAllBands
                )
            }
        ) {
            LazyVGrid(columns: bandColumns, spacing: PhotoStudio.Spacing.xs) {
                ForEach(ColorBand.allCases) { band in
                    PhotoInspectorSwatch(
                        title: band.displayName,
                        abbreviation: band.abbreviation,
                        color: swatch(band),
                        isSelected: session.activeColorBand == band,
                        action: { select(band) }
                    )
                }
            }

            PhotoAdjustmentSlider(
                value: session.adjustments.selectiveHSL[session.activeColorBand].hue,
                parameterName: "Hue"
            ) { value in
                session.mutate { $0.selectiveHSL[session.activeColorBand].hue = value }
            } onEnded: {
                session.commit()
            }

            PhotoAdjustmentSlider(
                value: session.adjustments.selectiveHSL[session.activeColorBand].saturation,
                parameterName: "Saturation"
            ) { value in
                session.mutate { $0.selectiveHSL[session.activeColorBand].saturation = value }
            } onEnded: {
                session.commit()
            }

            PhotoAdjustmentSlider(
                value: session.adjustments.selectiveHSL[session.activeColorBand].luminance,
                parameterName: "Luminance"
            ) { value in
                session.mutate { $0.selectiveHSL[session.activeColorBand].luminance = value }
            } onEnded: {
                session.commit()
            }
        }
    }

    private func select(_ band: ColorBand) {
        session.activeColorBand = band
    }

    private func resetAllBands() {
        session.mutate { $0.selectiveHSL = SelectiveHSL() }
        session.commit()
    }

    private func swatch(_ band: ColorBand) -> Color {
        Color(hue: band.hueCenter / 360, saturation: 0.82, brightness: 0.86)
    }
}
