import SwiftUI

struct IDEPreferencesIntStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step: Int = 1
    var valueWidth: Double = 24
    var valueSuffix = ""

    var body: some View {
        IDESettingsRow(title) {
            HStack(spacing: IDEAppearance.Spacing.xs) {
                Text("\(value)\(valueSuffix)")
                    .font(IDEAppearance.Typography.monoCaption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .monospacedDigit()
                    .frame(width: valueWidth, alignment: .trailing)
                    .accessibilityHidden(true)
                Stepper(title, value: $value, in: range, step: step)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel(title)
                    .accessibilityValue(Text("\(value)\(valueSuffix)"))
            }
        }
    }
}
