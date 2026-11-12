import SwiftUI

/// The diff tab's toolbar, after IntelliJ's: change and file navigation, Jump to Source, the
/// layout, whitespace and highlighting options, collapsing, synchronized scrolling, and the count.
struct IDEDiffToolbar: View {
    @Bindable var model: IDEDiffToolbarModel

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            if let session = model.session {
                IDEDiffToolbarContent(model: model, session: session)
            }
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(IDEAppearance.ColorToken.panel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(model.session?.request.title.hasSuffix("(agent)") == true ? IDEACPAccessibility.diff : "diff.toolbar")
        .accessibilityLabel(model.session?.request.title ?? "Diff")
        .overlay(alignment: .bottom) {
            Rectangle().fill(IDEAppearance.ColorToken.border).frame(height: 1)
        }
    }
}

#Preview {
    IDEDiffToolbar(model: IDEDiffToolbarModel())
        .frame(width: 600, height: 40)
}
