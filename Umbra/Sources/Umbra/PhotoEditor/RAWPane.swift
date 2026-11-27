import SwiftUI

struct RAWPane: View {
    @Bindable var session: PhotoEditorSession
    @AppStorage("photoEditor.module.raw") private var isExpanded = false

    var body: some View {
        PhotoInspectorModule(
            title: "RAW",
            isExpanded: $isExpanded,
            trailing: {
                PhotoInspectorResetButton(
                    isEnabled: !session.adjustments.raw.isIdentity,
                    action: resetRAW
                )
            }
        ) {
            ForEach(RAWParameter.allCases) { parameter in
                PhotoRAWParameterRow(session: session, parameter: parameter)
            }

            Button(
                session.adjustments.raw.lensCorrection ? "Lens Correction On" : "Lens Correction Off",
                systemImage: session.adjustments.raw.lensCorrection ? "camera.aperture" : "camera",
                action: toggleLensCorrection
            )
            .controlSize(.small)
            .tint(PhotoStudio.accent)
            .help("Apply vendor lens correction when the RAW file includes a profile")
        }
    }

    private func resetRAW() {
        session.mutate { $0.raw = .identity }
        session.commit()
    }

    private func toggleLensCorrection() {
        session.mutate { $0.raw.lensCorrection.toggle() }
        session.commit()
    }
}
