import SwiftUI

/// A pop-up picker in the settings control column.
struct IDESettingsPicker<Selection: Hashable, Content: View>: View {
    let title: String
    @Binding var selection: Selection
    @ViewBuilder var content: Content

    init(_ title: String, selection: Binding<Selection>, @ViewBuilder content: () -> Content) {
        self.title = title
        self._selection = selection
        self.content = content()
    }

    var body: some View {
        IDESettingsRow(title) {
            Picker(title, selection: $selection) { content }
                .labelsHidden()
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .frame(width: 260, alignment: .leading)
        }
    }
}
