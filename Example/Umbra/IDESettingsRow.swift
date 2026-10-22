import SwiftUI

/// A label on the left and its control on the right of a fixed column, so every row of a card
/// lines up.
struct IDESettingsRow<Control: View>: View {
    static var labelWidth: Double { 150 }

    let title: String
    @ViewBuilder var control: Control

    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.md) {
            Text(title)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .frame(width: Self.labelWidth, alignment: .leading)
            control
            Spacer(minLength: 0)
        }
    }
}
