import SwiftUI

/// "Info" module at the top of the Develop stack: grouped file / image / camera / location facts
/// pulled from `PhotoImageInfo`, with a disclosure for the full ImageIO dictionary.
struct PhotoInfoPane: View {
    @Bindable var session: PhotoEditorSession
    @AppStorage("photoEditor.module.info") private var isExpanded = true
    @State private var showAllMetadata = false

    private var info: PhotoImageInfo { session.imageInfo }

    var body: some View {
        PhotoInspectorModule(
            title: "Info",
            isExpanded: $isExpanded,
            trailing: {
                if !info.isEmpty {
                    PhotoCopyButton(text: info.plainText)
                        .accessibilityLabel("Copy all metadata")
                }
            }
        ) {
            if info.isEmpty {
                Text("No metadata for this image.")
                    .font(PhotoStudio.Typography.caption)
                    .foregroundStyle(PhotoStudio.Photo.label)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(info.sections) { section in
                    sectionHeader(section.title)
                    ForEach(section.entries) { entry in
                        PhotoInfoRow(label: entry.label, value: entry.value)
                    }
                }

                if !info.allEntries.isEmpty {
                    Button {
                        showAllMetadata.toggle()
                    } label: {
                        HStack(spacing: PhotoStudio.Spacing.xs) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .rotationEffect(.degrees(showAllMetadata ? 90 : 0))
                            Text("All metadata (\(info.allEntries.count))")
                                .font(PhotoStudio.Typography.captionEmphasis)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(PhotoStudio.Photo.label)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, PhotoStudio.Spacing.xs)

                    if showAllMetadata {
                        ForEach(info.allEntries) { entry in
                            PhotoInfoRow(label: entry.label, value: entry.value, labelWidth: 150)
                        }
                    }
                }
            }
        }
        .onChange(of: session.sourceURL) { showAllMetadata = false }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(PhotoStudio.Typography.caption)
            .foregroundStyle(PhotoStudio.Photo.label.opacity(0.8))
            .textCase(.uppercase)
            .tracking(0.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, PhotoStudio.Spacing.xs)
    }
}
