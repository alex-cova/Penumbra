import SwiftUI

/// Close Editor Group, then the buttons language modules and the project system contribute
/// (`IDELanguageModule.toolbarItems`), in their order.
struct IDEToolbarActionCluster: View {
    let showsCloseGroup: Bool
    let items: [IDEToolbarItem]
    let closeActivePane: () -> Void

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.xxs) {
            if showsCloseGroup {
                IDEIconButton(
                    systemImage: "rectangle.slash",
                    help: "Close Editor Group",
                    action: closeActivePane
                )
            }

            ForEach(items) { item in
                switch item.content {
                case .button(let button):
                    IDEIconButton(
                        systemImage: button.systemImage,
                        help: button.help,
                        tint: button.tint,
                        isActive: button.isActive,
                        action: button.action
                    )
                    .disabled(!button.isEnabled)
                case .custom(let view):
                    view
                }
            }
        }
    }
}
