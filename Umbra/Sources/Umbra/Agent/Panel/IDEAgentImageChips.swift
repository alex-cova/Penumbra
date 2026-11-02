import SwiftUI

/// The images going with the next message: a thumbnail chip each, with a remove button.
/// Matches the composer card style used by the browser-notes and queued-message chips.
struct IDEAgentImageChips: View {
    let images: [IDEAttachedImage]
    let remove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: IDEAppearance.Spacing.xs) {
                ForEach(images) { image in
                    IDEAgentImageChip(image: image, remove: { remove(image.id) })
                }
            }
        }
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Attached images")
    }
}

private struct IDEAgentImageChip: View {
    let image: IDEAttachedImage
    let remove: () -> Void

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            if let thumbnail = image.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 48, maxHeight: 32)
                    .clipShape(.rect(cornerRadius: 4))
                    .accessibilityHidden(true)
            }
            Text("Image")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .lineLimit(1)
            Button("Remove attached image", systemImage: "xmark", action: remove)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
                .help("Remove this image from the next message")
                .accessibilityLabel("Remove attached image")
        }
        .padding(IDEAppearance.Spacing.xs)
        .background(IDEAppearance.ColorToken.card)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous))
    }
}
