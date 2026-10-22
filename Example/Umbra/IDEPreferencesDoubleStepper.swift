import SwiftUI

struct IDEPreferencesDoubleStepper: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var fractionLength: Int = 0
    var valueWidth: Double = 28

    var body: some View {
        IDESettingsRow(title) {
            HStack(spacing: IDEAppearance.Spacing.xs) {
                Text(value, format: .number.precision(.fractionLength(fractionLength)))
                    .font(IDEAppearance.Typography.monoCaption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .monospacedDigit()
                    .frame(width: valueWidth, alignment: .trailing)
                    .accessibilityHidden(true)
                Stepper(title, value: $value, in: range, step: step)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel(title)
                    .accessibilityValue(
                        Text(value, format: .number.precision(.fractionLength(fractionLength)))
                    )
            }
        }
    }
}
