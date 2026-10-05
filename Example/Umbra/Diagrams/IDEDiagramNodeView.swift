import DiagramKit
import SwiftUI

/// A UML box for a Java type, or a plain card for a Gradle project or library.
struct IDEDiagramNodeView: View {
    let node: IDEDiagramNode
    let isSelected: Bool
    let highlight: NodeHighlightLevel
    let dark: Bool

    private static let cornerRadius: CGFloat = 6

    var body: some View {
        let colors = IDEDiagramPalette.colors(for: node.kind, dark: dark)
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius)
        VStack(spacing: 0) {
            header(colors: colors)
            if showsCompartments {
                compartment(IDEDiagramNodeMetrics.displayed(node.attributes), count: node.attributes.count)
                compartment(IDEDiagramNodeMetrics.displayed(node.methods), count: node.methods.count)
            }
        }
        .frame(width: node.frame.width, height: node.frame.height, alignment: .top)
        .background(Color(hex: colors.fill))
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(
                isSelected ? IDEAppearance.ColorToken.accent : Color(hex: colors.stroke),
                lineWidth: isSelected ? 2 : 1
            )
        }
        .opacity(DiagramFocusResolver.nodeOpacity(level: highlight))
        .contentShape(shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var showsCompartments: Bool {
        node.kind.isType && node.kind != .externalType
    }

    private var headerHeight: CGFloat {
        IDEDiagramNodeMetrics.headerHeight + (node.subtitle.isEmpty ? 0 : IDEDiagramNodeMetrics.lineHeight - 2)
    }

    private func header(colors: IDEDiagramPalette) -> some View {
        HStack(spacing: 6) {
            badge(colors: colors)
            VStack(alignment: .leading, spacing: 0) {
                Text(node.title)
                    .font(.system(size: 12, weight: .semibold))
                    .italic(node.kind == .abstractClass)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !node.subtitle.isEmpty {
                    Text(node.subtitle)
                        .font(.system(size: 9.5))
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, IDEDiagramNodeMetrics.horizontalPadding)
        .frame(maxWidth: .infinity)
        .frame(height: headerHeight)
        .background(Color(hex: colors.header))
    }

    @ViewBuilder
    private func badge(colors: IDEDiagramPalette) -> some View {
        let tint = Color(hex: colors.stroke)
        Group {
            if let letter = Self.letter(for: node.kind) {
                Text(letter)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
            } else {
                Image(systemName: Self.symbol(for: node.kind))
                    .font(.system(size: 9, weight: .bold))
            }
        }
        .foregroundStyle(tint)
        .frame(width: 16, height: 16)
        .background(tint.opacity(0.18), in: Circle())
    }

    private func compartment(_ lines: [String], count: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(line.hasPrefix("- ") ? IDEAppearance.ColorToken.muted : IDEAppearance.ColorToken.foreground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(height: IDEDiagramNodeMetrics.lineHeight, alignment: .leading)
            }
        }
        .padding(.horizontal, IDEDiagramNodeMetrics.horizontalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: IDEDiagramNodeMetrics.compartmentHeight(count), alignment: .center)
        .overlay(alignment: .top) {
            Rectangle().fill(IDEAppearance.ColorToken.border.opacity(0.7)).frame(height: 1)
        }
    }

    private var accessibilityLabel: String {
        node.subtitle.isEmpty ? node.title : "\(node.title), \(node.subtitle)"
    }

    static func letter(for kind: IDEDiagramNodeKind) -> String? {
        switch kind {
        case .classType: "C"
        case .abstractClass: "A"
        case .interfaceType: "I"
        case .enumType: "E"
        case .recordType: "R"
        case .annotationType: "@"
        case .externalType: "C"
        case .jsonObject: "{}"
        case .jsonArray: "[]"
        case .project, .library, .replacedLibrary, .unresolvedLibrary, .jsonValue: nil
        }
    }

    static func symbol(for kind: IDEDiagramNodeKind) -> String {
        switch kind {
        case .project: "square.stack.3d.up.fill"
        case .library: "shippingbox.fill"
        case .replacedLibrary: "arrow.triangle.swap"
        case .unresolvedLibrary: "exclamationmark.triangle.fill"
        case .jsonValue: "text.quote"
        default: "circle"
        }
    }
}
