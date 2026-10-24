import SwiftUI

/// The glyph-only button used in panel headers and tool-window toolbars: a fixed square hit target,
/// muted until the pointer is over it or it is on, a selection fill while on.
///
/// The titlebar's own icon buttons are `IDEToolbarIconButton`; this one is for everything inside a panel.
/// A toolbar picks its size once with `.ideIconButtonSize(_:)` instead of on every button.
struct IDEIconButton: View {
    enum Size: Equatable {
        /// Dense tool-window toolbars (Gradle, Maven).
        case compact
        /// Panel and sidebar header rows.
        case regular
        /// Popover and sheet headers, where the glyph is a little larger and lighter.
        case header

        fileprivate var glyph: Font {
            switch self {
            case .compact: .system(size: IDEAppearance.IconSize.toolbarGlyph - 1, weight: .medium)
            case .regular: .system(size: IDEAppearance.IconSize.toolbarGlyph, weight: .medium)
            case .header: .system(size: IDEAppearance.IconSize.titlebarGlyph)
            }
        }

        fileprivate var width: CGFloat {
            self == .compact ? IDEAppearance.Spacing.iconButton - 2 : IDEAppearance.Spacing.iconButton
        }

        fileprivate var height: CGFloat { IDEAppearance.Spacing.iconButton }
    }

    let systemImage: String
    let help: String
    /// A fixed color for the glyph (a run button's green); otherwise it follows hover and `isActive`.
    var tint: Color?
    var isActive = false
    var isDisabled = false
    let action: () -> Void

    @Environment(\.ideIconButtonSize) private var size
    @Environment(\.isEnabled) private var isEnvironmentEnabled
    @State private var isHovering = false

    private var isEnabled: Bool { isEnvironmentEnabled && !isDisabled }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(size.glyph)
                .foregroundStyle(tint ?? (isActive || (isHovering && isEnabled) ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted))
                .frame(width: size.width, height: size.height)
                .background(background)
                .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isEnabled ? 1 : IDEAppearance.Opacity.disabled)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .focusable(false)
    }

    private var background: Color {
        if isActive { return IDEAppearance.ColorToken.selection }
        return isHovering && isEnabled ? IDEAppearance.ColorToken.controlHover : Color.clear
    }
}

private struct IDEIconButtonSizeKey: EnvironmentKey {
    static let defaultValue = IDEIconButton.Size.regular
}

extension EnvironmentValues {
    var ideIconButtonSize: IDEIconButton.Size {
        get { self[IDEIconButtonSizeKey.self] }
        set { self[IDEIconButtonSizeKey.self] = newValue }
    }
}

extension View {
    /// Sets the size of every `IDEIconButton` inside.
    func ideIconButtonSize(_ size: IDEIconButton.Size) -> some View {
        environment(\.ideIconButtonSize, size)
    }
}
