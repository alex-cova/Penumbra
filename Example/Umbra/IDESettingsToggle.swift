import SwiftUI

/// A checkbox with an optional line of explanation under it.
struct IDESettingsToggle: View {
    let title: String
    @Binding var isOn: Bool
    var detail: String?

    init(_ title: String, isOn: Binding<Bool>, detail: String? = nil) {
        self.title = title
        self._isOn = isOn
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.checkbox)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
            if let detail {
                Text(detail)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }
        }
    }
}
