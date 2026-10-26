import SwiftUI

/// A settings row with the current value and a small stepper. Whole numbers show an optional
/// suffix ("ms"), fractional ones a fixed number of decimals; both are initialisers over one body.
struct IDEPreferencesStepper<Value: Strideable>: View {
    let title: String
    @Binding var value: Value
    let range: ClosedRange<Value>
    let step: Value.Stride
    let valueWidth: Double
    let text: (Value) -> String

    var body: some View {
        IDESettingsRow(title) {
            HStack(spacing: IDEAppearance.Spacing.xs) {
                Text(text(value))
                    .font(IDEAppearance.Typography.monoCaption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .monospacedDigit()
                    .frame(width: valueWidth, alignment: .trailing)
                    .accessibilityHidden(true)
                Stepper(title, value: $value, in: range, step: step)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel(title)
                    .accessibilityValue(Text(text(value)))
            }
        }
    }
}

extension IDEPreferencesStepper where Value == Int {
    init(title: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int = 1, valueWidth: Double = 24, valueSuffix: String = "") {
        self.init(
            title: title, value: value, range: range, step: step, valueWidth: valueWidth,
            text: { "\($0)\(valueSuffix)" })
    }
}

extension IDEPreferencesStepper where Value == Double {
    init(title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double = 1, fractionLength: Int = 0, valueWidth: Double = 28) {
        self.init(
            title: title, value: value, range: range, step: step, valueWidth: valueWidth,
            text: { $0.formatted(.number.precision(.fractionLength(fractionLength))) })
    }
}
