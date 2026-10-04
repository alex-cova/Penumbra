import SwiftUI

/// The list above the composer: commands after `/`, files after `@`. Keys move and accept through
/// the composer field; a click highlights a row and asks the field to accept it.
struct IDEAgentSuggestionList: View {
    let state: IDEAgentComposerState
    let accept: (Int) -> Void

    private static let maxVisibleRows = 8

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(state.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                        row(suggestion, isSelected: index == state.selectedIndex)
                            .id(suggestion.id)
                            .contentShape(Rectangle())
                            .onTapGesture { accept(index) }
                    }
                }
            }
            .onChange(of: state.selectedIndex) {
                if let selected = state.selected { proxy.scrollTo(selected.id) }
            }
        }
        .frame(maxHeight: CGFloat(min(state.suggestions.count, Self.maxVisibleRows)) * Self.rowHeight)
        .background(IDEAppearance.ColorToken.card)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous)
                .strokeBorder(IDEAppearance.ColorToken.border))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggestions")
    }

    private static let rowHeight: CGFloat = 28

    private func row(_ suggestion: IDEAgentSuggestion, isSelected: Bool) -> some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            Image(systemName: suggestion.icon)
                .font(.system(size: IDEAppearance.IconSize.toolbarGlyph))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(width: 16)
            Text(suggestion.title)
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .lineLimit(1)
                .truncationMode(.middle)
            if let detail = suggestion.detail {
                Text(detail)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .frame(height: Self.rowHeight)
        .background(isSelected ? IDEAppearance.ColorToken.controlHover : .clear)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
