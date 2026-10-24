import SwiftUI

/// A color well in the settings control column.
struct IDESettingsColorWell: View {
    let title: String
    @Binding var hex: UInt32
    var isEnabled = true

    private func colorBinding() -> Binding<Color> {
        Binding(
            get: { Color(hex: hex) },
            set: { hex = $0.sRGBHex ?? hex }
        )
    }

    var body: some View {
        IDESettingsRow(title) {
            ColorPicker(
                title,
                selection: colorBinding(),
                supportsOpacity: false
            )
            .labelsHidden()
            .disabled(!isEnabled)
            .accessibilityLabel(title)
        }
    }
}
