import SwiftUI

/// The small badge at the top right of a Java editor: how many errors, warnings and weaker
/// problems the file has, or a check mark. A click opens the Problems tab for the file.
struct IDEInspectionWidget: View {
    static let defaultsKey = "umbra.editor.showsInspectionWidget"

    @Environment(IDEWorkspace.self) private var workspace
    @AppStorage(IDEInspectionWidget.defaultsKey) private var isEnabled = true
    let paneID: UUID

    private var url: URL? {
        workspace.workbench.layout.findPane(id: paneID)?.selectedDocument?.url
    }

    var body: some View {
        if isEnabled, let url, url.pathExtension.lowercased() == "java" {
            let counts = workspace.problems.counts(for: url)
            Button {
                workspace.inspectionRuns.selection = .file
                workspace.showProblems()
            } label: {
                HStack(spacing: 6) {
                    if counts.errors + counts.warnings + counts.weaker == 0 {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(IDEAppearance.ColorToken.gitAdded)
                    } else {
                        if counts.errors > 0 { badge("xmark.octagon.fill", counts.errors, IDEAppearance.ColorToken.error) }
                        if counts.warnings > 0 { badge("exclamationmark.triangle.fill", counts.warnings, IDEAppearance.ColorToken.gitModified) }
                        if counts.weaker > 0 { badge("lightbulb.fill", counts.weaker, IDEAppearance.ColorToken.muted) }
                    }
                }
                .font(.system(size: 10))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(IDEAppearance.ColorToken.card.opacity(0.9), in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
            .padding(.trailing, 18)
            .help("Problems in this file. Click to open them; F2 goes to the next one.")
            .accessibilityLabel("\(counts.errors) errors, \(counts.warnings) warnings, \(counts.weaker) weaker problems in this file")
        }
    }

    private func badge(_ symbol: String, _ count: Int, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).foregroundStyle(color)
            Text("\(count)").font(IDEAppearance.Typography.monoSmall).foregroundStyle(IDEAppearance.ColorToken.foreground)
        }
    }
}
