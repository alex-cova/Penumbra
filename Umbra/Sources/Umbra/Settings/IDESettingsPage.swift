import SwiftUI

/// The page every domain pane sits in: a large title, then its sections.
struct IDESettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xl) {
                Text(title)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                    .accessibilityAddTraits(.isHeader)
                content
            }
            .font(IDEAppearance.Typography.body)
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, IDEAppearance.Spacing.xl)
            .padding(.vertical, IDEAppearance.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollIndicators(.automatic)
        .ideSettingsScrollSurface()
    }
}
