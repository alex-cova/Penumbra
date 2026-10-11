import HexKit
import SwiftUI

/// Hex tab: banner, find bar, the canvas, and the data inspector.
struct IDEHexRootView: View {
    @Bindable var session: IDEHexSession

    var body: some View {
        VStack(spacing: 0) {
            if session.showSniffBanner {
                banner(
                    "Opened as hex: this file does not look like text.",
                    action: "Open as Text",
                    actionHandler: { session.onOpenAsText?() }
                ) {
                    session.dismissSniffBanner()
                }
            }
            if session.externalChange {
                HStack(spacing: 8) {
                    Text("Changed on disk")
                    Button("Reload") { session.onReloadFromDisk?() }
                    Button("Keep Mine") { session.keepMine() }
                    Button("Compare") { session.onCompareWithDisk?() }
                    Spacer()
                }
                .font(.caption)
                .padding(6)
                .background(IDEAppearance.ColorToken.gitModified.opacity(0.25))
            }
            if session.largeFileGated {
                HStack {
                    Text("This file is open read-only. Saving rewrites the whole file.")
                    Button("Make Editable") { session.onMakeEditable?() }
                    Spacer()
                }
                .font(.caption)
                .padding(6)
            }
            if session.findBarVisible {
                IDEHexFindBar(session: session)
            }
            SplitPanes(
                minPrimary: 200,
                minSecondary: session.inspectorVisible ? 180 : 0,
                idealSecondary: 240,
                storageKey: "umbra.hex.inspector",
                priority: .secondary,
                hiddenSide: session.inspectorVisible ? nil : .secondary
            ) {
                IDEHexCanvasRepresentable(session: session)
            } secondary: {
                IDEHexInspectorView(session: session)
            }
            if session.showsDiskCompare, let differences = session.diskDifferences {
                diskCompare(differences)
            }
            if let progress = session.saveProgressText {
                HStack(spacing: 8) {
                    Text(progress)
                        .font(.caption.monospaced())
                        .accessibilityIdentifier("hex.saveProgress")
                    if let save = session.saveProgress, save.total > 0 {
                        ProgressView(value: Double(save.written), total: Double(save.total))
                    }
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(progress)
            }
            if let label = session.formatLabel {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
            }
        }
        .background(IDEAppearance.ColorToken.editor)
        .sheet(isPresented: $session.showsGoToOffset) {
            IDEHexGoToOffsetSheet(session: session)
        }
    }

    private func banner(_ text: String, action: String, actionHandler: @escaping () -> Void, dismiss: @escaping () -> Void) -> some View {
        HStack {
            Text(text).font(.caption)
            Button(action, action: actionHandler)
            Spacer()
            Button("Dismiss", action: dismiss)
        }
        .padding(6)
        .background(IDEAppearance.ColorToken.tabHover)
    }

    private func diskCompare(_ differences: [HexDiskDifference]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Compare with Disk")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button("Close") { session.showsDiskCompare = false }
            }
            if differences.isEmpty {
                Text("The editor matches the file on disk.")
                    .font(.caption)
            } else {
                ForEach(Array(differences.prefix(64).enumerated()), id: \.offset) { _, difference in
                    Text("\(difference.range.lowerBound)–\(difference.range.upperBound)")
                        .font(.caption.monospaced())
                }
                if differences.count > 64 {
                    Text("\(differences.count - 64) more ranges")
                        .font(.caption)
                }
            }
        }
        .padding(8)
        .frame(maxHeight: 120)
    }
}

struct IDEHexCanvasRepresentable: NSViewRepresentable {
    var session: IDEHexSession

    func makeNSView(context: Context) -> IDEHexCanvasView {
        let view = IDEHexCanvasView()
        view.session = session
        return view
    }

    func updateNSView(_ view: IDEHexCanvasView, context: Context) {
        view.session = session
        view.needsDisplay = true
    }
}
