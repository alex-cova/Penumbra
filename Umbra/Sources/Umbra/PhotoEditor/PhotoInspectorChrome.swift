import AppKit
import SwiftUI

/// Quiet copy button for metadata rows. Umbra has no shared copy-button helper, so the photo
/// editor owns this one.
struct PhotoCopyButton: View {
    let text: String
    var help: String = "Copy"

    @State private var didCopy = false

    var body: some View {
        Button(help, systemImage: didCopy ? "checkmark" : "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            didCopy = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                didCopy = false
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.mini)
        .foregroundStyle(PhotoStudio.Photo.label)
        .help(help)
    }
}

/// Collapsible Lightroom-style module: a full-bleed header bar on the recessed panel color with a
/// right-aligned disclosure triangle, over an indented content area. An optional `trailing` view
/// (a reset button, a "+" action) sits in the header without toggling expansion.
struct PhotoInspectorModule<Trailing: View, Content: View>: View {
    let title: LocalizedStringResource
    @Binding var isExpanded: Bool
    let trailing: Trailing
    let content: Content

    init(
        title: LocalizedStringResource,
        isExpanded: Binding<Bool>,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self._isExpanded = isExpanded
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                VStack(alignment: .leading, spacing: PhotoStudio.Spacing.sm) {
                    content
                }
                .padding(.horizontal, PhotoStudio.Spacing.md)
                .padding(.top, PhotoStudio.Spacing.sm)
                .padding(.bottom, PhotoStudio.Spacing.md)
            }
        }
        .background(PhotoStudio.Photo.panel)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PhotoStudio.Photo.hairline)
                .frame(height: 1)
        }
        .photoAnimation(PhotoStudio.Motion.quick, value: isExpanded)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: PhotoStudio.Spacing.xs) {
            Button(action: toggleExpanded) {
                HStack(spacing: PhotoStudio.Spacing.xs) {
                    Text(title)
                        .font(PhotoStudio.Typography.captionEmphasis)
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .foregroundStyle(PhotoStudio.Photo.label)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(PhotoStudio.Photo.label.opacity(0.7))
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? Text("Collapse \(title)") : Text("Expand \(title)"))
            .accessibilityAddTraits(.isHeader)

            trailing
        }
        .padding(.horizontal, PhotoStudio.Spacing.md)
        .frame(height: 30)
        .background(PhotoStudio.Photo.panelDeep)
    }

    private func toggleExpanded() {
        isExpanded.toggle()
    }
}

extension PhotoInspectorModule where Trailing == EmptyView {
    init(
        title: LocalizedStringResource,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) {
        self.init(title: title, isExpanded: isExpanded, trailing: { EmptyView() }, content: content)
    }
}

/// Right-aligned editable numeric readout for a slider row. Reads as plain text until hovered or
/// focused, then becomes a field; commits a clamped value on Return or focus loss.
struct PhotoInspectorValueField: View {
    let value: Double
    let range: ClosedRange<Double>
    var showsSign: Bool = true
    let onCommit: (Double) -> Void

    @State private var text: String = ""
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(PhotoStudio.Typography.metric)
            .foregroundStyle(PhotoStudio.Photo.value)
            .multilineTextAlignment(.trailing)
            .frame(width: 42)
            .focused($isFocused)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                (isHovered || isFocused) ? PhotoStudio.Photo.panelDeep : Color.clear,
                in: .rect(cornerRadius: PhotoStudio.Radius.xs)
            )
            .overlay {
                if isHovered || isFocused {
                    RoundedRectangle(cornerRadius: PhotoStudio.Radius.xs)
                        .strokeBorder(PhotoStudio.Photo.hairline, lineWidth: 1)
                }
            }
            .onHover { isHovered = $0 }
            .contentTransition(.numericText())
            .onAppear { text = formatted(value) }
            .onChange(of: value) {
                if !isFocused { text = formatted(value) }
            }
            .onChange(of: isFocused) {
                if !isFocused { commit() }
            }
            .onSubmit(commit)
            .accessibilityLabel("Value")
            .accessibilityValue(formatted(value))
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "+", with: "")
        if let parsed = Double(trimmed) {
            let clamped = min(range.upperBound, max(range.lowerBound, parsed))
            onCommit(clamped)
            text = formatted(clamped)
        } else {
            text = formatted(value)
        }
    }

    private func formatted(_ raw: Double) -> String {
        raw.formatted(
            .number.precision(.fractionLength(0))
                .sign(strategy: showsSign ? .always() : .automatic)
        )
    }
}

/// Quiet trailing reset used on module headers and slider rows.
struct PhotoInspectorResetButton: View {
    var isEnabled: Bool = true
    var action: () -> Void

    var body: some View {
        Button("Reset", systemImage: "arrow.counterclockwise", action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .controlSize(.mini)
            .foregroundStyle(PhotoStudio.Photo.label)
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0)
            .help("Reset")
            .accessibilityHidden(!isEnabled)
    }
}

/// Compact selectable chip for aspect ratios, curve channels, and similar choice rows.
struct PhotoInspectorChip: View {
    let title: LocalizedStringResource
    var isSelected: Bool
    var tint: Color = PhotoStudio.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(PhotoStudio.Typography.captionEmphasis)
                .foregroundStyle(isSelected ? tint : PhotoStudio.Photo.label)
                .frame(maxWidth: .infinity)
                .padding(.vertical, PhotoStudio.Spacing.xs)
                .background(
                    isSelected ? tint.opacity(0.16) : Color.clear,
                    in: .rect(cornerRadius: PhotoStudio.Radius.xs)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: PhotoStudio.Radius.xs)
                        .strokeBorder(
                            isSelected ? tint.opacity(0.7) : PhotoStudio.Photo.hairline,
                            lineWidth: 1
                        )
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Label / value row for the Info module. Like `CopyableValueRow` but painted from the fixed
/// `PhotoStudio.Photo` palette so it does not invert against the studio-gray inspector panel.
struct PhotoInfoRow: View {
    let label: String
    let value: String
    var labelWidth: CGFloat = 96

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PhotoStudio.Spacing.sm) {
            Text(label)
                .font(PhotoStudio.Typography.caption)
                .foregroundStyle(PhotoStudio.Photo.label)
                .frame(width: labelWidth, alignment: .leading)

            Text(value)
                .font(PhotoStudio.Typography.metric)
                .foregroundStyle(PhotoStudio.Photo.value)
                .textSelection(.enabled)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            PhotoCopyButton(text: value)
                .opacity(isHovering ? 1 : 0)
                .accessibilityLabel("Copy \(label)")
        }
        .padding(.horizontal, PhotoStudio.Spacing.xs)
        .padding(.vertical, 3)
        .background(
            isHovering ? PhotoStudio.Photo.panelDeep : Color.clear,
            in: .rect(cornerRadius: PhotoStudio.Radius.xs)
        )
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

/// Color-band swatch with a letter so selection is not color-only.
struct PhotoInspectorSwatch: View {
    let title: LocalizedStringResource
    let abbreviation: String
    let color: Color
    var isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                RoundedRectangle(cornerRadius: PhotoStudio.Radius.xs)
                    .fill(color)
                    .frame(height: 16)
                    .overlay {
                        RoundedRectangle(cornerRadius: PhotoStudio.Radius.xs)
                            .strokeBorder(
                                isSelected ? PhotoStudio.Photo.value : Color.black.opacity(0.25),
                                lineWidth: isSelected ? 2 : 1
                            )
                    }

                Text(abbreviation)
                    .font(PhotoStudio.Typography.captionEmphasis)
                    .foregroundStyle(isSelected ? PhotoStudio.Photo.value : PhotoStudio.Photo.label)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(title))
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
