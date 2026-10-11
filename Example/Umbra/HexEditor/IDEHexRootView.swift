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
            HStack(spacing: 0) {
                SplitPanes(
                    minPrimary: 200,
                    minSecondary: session.inspectorVisible ? 180 : 0,
                    idealSecondary: 240,
                    storageKey: "umbra.hex.inspector",
                    priority: .secondary,
                    hiddenSide: session.inspectorVisible ? nil : .secondary
                ) {
                    IDEHexCanvasRepresentable(session: session, stamp: canvasStamp)
                } secondary: {
                    IDEHexInspectorView(session: session)
                }
                if !session.inspectorVisible {
                    inspectorRail
                }
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

    /// Read by the canvas representable so a caret, match, or mode change outside the view still repaints.
    private var canvasStamp: HexCanvasStamp {
        HexCanvasStamp(
            generation: session.renderGeneration,
            textPane: session.textPaneFocused,
            insert: session.insertMode,
            lowNibble: session.lowNibble,
            matchIndex: session.matchIndex,
            matchCount: session.matches.count,
            firstMatch: session.matches.first?.lowerBound,
            selection: session.selection
        )
    }

    /// Slim strip left behind when the inspector is collapsed. Clicking it opens the pane again.
    private var inspectorRail: some View {
        Button {
            session.setInspectorVisible(true)
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 9, weight: .semibold))
                Text("Data Inspector")
                    .font(.caption2)
                    .fixedSize()
                    .rotationEffect(.degrees(-90))
                    .frame(width: 14, height: 96)
                Spacer(minLength: 0)
            }
            .padding(.top, 8)
            .frame(width: 22)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show Data Inspector")
        .accessibilityLabel("Show Data Inspector")
        .background(IDEAppearance.ColorToken.sidebar)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(IDEAppearance.ColorToken.panelBorder)
                .frame(width: 1)
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

struct HexCanvasStamp: Equatable {
    var generation: Int
    var textPane: Bool
    var insert: Bool
    var lowNibble: Bool
    var matchIndex: Int?
    var matchCount: Int
    var firstMatch: Int64?
    var selection: Range<Int64>
}

struct IDEHexCanvasRepresentable: NSViewRepresentable {
    var session: IDEHexSession
    var stamp: HexCanvasStamp

    func makeNSView(context: Context) -> IDEHexCanvasView {
        let view = IDEHexCanvasView()
        view.session = session
        context.coordinator.stamp = stamp
        return view
    }

    func updateNSView(_ view: IDEHexCanvasView, context: Context) {
        view.session = session
        context.coordinator.stamp = stamp
        view.needsDisplay = true
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var stamp: HexCanvasStamp?
    }
}
