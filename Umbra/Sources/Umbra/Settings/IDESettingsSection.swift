import SwiftUI

/// One titled group of settings: a heading above a rounded card that holds the rows, with an
/// optional explanation underneath.
struct IDESettingsSection<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder var content: Content

    init(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            Text(title)
                .font(IDEAppearance.Typography.titlebarTitle)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: IDEAppearance.Spacing.md) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(IDEAppearance.Spacing.lg)
            .background(
                IDEAppearance.ColorToken.panel,
                in: .rect(cornerRadius: IDEAppearance.Radius.panel)
            )
            .overlay {
                let border: RoundedRectangle = .rect(cornerRadius: IDEAppearance.Radius.panel)
                border
                    .strokeBorder(IDEAppearance.ColorToken.border, lineWidth: 1)
                    .allowsHitTesting(false)
            }

            if let footer {
                Text(footer)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, IDEAppearance.Spacing.xs)
            }
        }
    }
}
