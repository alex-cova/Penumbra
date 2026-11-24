import AgentKit
import AppKit
import SwiftUI

/// One command a chat ran, for the commands drawer.
struct IDEAgentCommandItem: Identifiable, Equatable {
    /// The tool call's entry.
    var id: UUID
    var line: String
    var isRunning: Bool
    var isError: Bool
    /// The output as the card shows it: live while it runs, the result once it finished.
    var output: String
}

/// The commands of a chat, in the order they ran: `run_command` (including `!command`), `gradle`,
/// `run_tests` and `maven`. Pure.
enum IDEAgentCommandLog {
    static func items(_ entries: [IDEAgentEntry]) -> [IDEAgentCommandItem] {
        entries.compactMap { entry in
            guard case .toolCall(let name) = entry.kind, let line = commandLine(name: name, arguments: entry.text) else { return nil }
            // Like the card: the streamed output in full when there is one, else the result.
            let output = entry.liveOutput.isEmpty ? entry.output?.text ?? "" : entry.liveOutput
            return IDEAgentCommandItem(
                id: entry.id, line: line, isRunning: entry.output == nil, isError: entry.output?.isError == true, output: output)
        }
    }

    static func commandLine(name: String, arguments: String) -> String? {
        if let line = IDEAgentToolSummary.commandLine(name: name, arguments: arguments) { return line }
        guard name == "maven", let object = (try? JSONValue(parsing: arguments))?.objectValue else { return nil }
        let goals = object["goals"]?.arrayValue?.compactMap(\.stringValue) ?? []
        guard !goals.isEmpty else { return nil }
        let options = object["options"]?.arrayValue?.compactMap(\.stringValue) ?? []
        return (["mvn"] + goals + options).joined(separator: " ")
    }
}

/// A drawer between the transcript and the message box: the chat's commands, and the output of the one
/// selected (the newest until another is picked), following while it runs. It shows what the transcript
/// already holds; it is not a shell.
struct IDEAgentCommandsDrawer: View {
    let items: [IDEAgentCommandItem]
    let close: () -> Void
    let showInTranscript: (UUID) -> Void

    @State private var selectedID: UUID?

    static let height: CGFloat = 260
    private static let rowHeight: CGFloat = 22
    private static let listHeight: CGFloat = 88

    private var selected: IDEAgentCommandItem? {
        items.first { $0.id == selectedID } ?? items.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: IDEAppearance.Spacing.xs) {
                Text("Commands")
                    .font(IDEAppearance.Typography.sectionHeader)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                Text("\(items.count)")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                Spacer(minLength: 0)
                if let selected {
                    IDEIconButton(systemImage: "doc.on.doc", help: "Copy Output") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(selected.output, forType: .string)
                    }
                    IDEIconButton(systemImage: "text.line.first.and.arrowtriangle.forward", help: "Show in Transcript") {
                        showInTranscript(selected.id)
                    }
                }
                IDEIconButton(systemImage: "xmark", help: "Close Commands", action: close)
            }
            .padding(.horizontal, IDEAppearance.Spacing.sm)
            .padding(.vertical, IDEAppearance.Spacing.xs)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { item in
                            row(item).id(item.id)
                        }
                    }
                }
                // As tall as its rows, up to about four; the output gets the rest.
                .frame(height: min(Self.listHeight, CGFloat(items.count) * Self.rowHeight))
                .onAppear { if let last = items.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                .onChange(of: items.count) { if selectedID == nil, let last = items.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            Divider().overlay(IDEAppearance.ColorToken.border)
            IDEAgentOutputTextView(text: selected?.output ?? "", isError: selected?.isError == true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: Self.height)
        .background(IDEAppearance.ColorToken.card)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous))
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.bottom, IDEAppearance.Spacing.xs)
    }

    private func row(_ item: IDEAgentCommandItem) -> some View {
        Button { selectedID = item.id } label: {
            HStack(spacing: IDEAppearance.Spacing.xs) {
                Group {
                    if item.isRunning {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: item.isError ? "xmark.circle.fill" : "checkmark.circle")
                            .foregroundStyle(item.isError ? IDEAppearance.ColorToken.error : IDEAppearance.ColorToken.muted)
                    }
                }
                .frame(width: 14)
                Text(item.line)
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, IDEAppearance.Spacing.sm)
            .frame(height: Self.rowHeight)
            .background(item.id == selected?.id ? IDEAppearance.ColorToken.selection : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.line)
        .accessibilityLabel("\(item.line), \(item.isRunning ? "running" : item.isError ? "failed" : "finished")")
    }
}

/// Read-only monospaced output in an `NSTextView`: outputs reach 200 KB (`IDEAgentLiveOutput.limit`), which a
/// SwiftUI `Text` lays out slowly. Follows the end while the user has not scrolled up.
struct IDEAgentOutputTextView: NSViewRepresentable {
    let text: String
    let isError: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        if let textView = scroll.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.textContainerInset = NSSize(width: 6, height: 6)
            textView.isAutomaticLinkDetectionEnabled = false
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        let color = isError ? NSColor(IDEAppearance.ColorToken.error) : NSColor(IDEAppearance.ColorToken.foreground)
        let shown = text.isEmpty ? "No output yet." : text
        guard textView.string != shown || context.coordinator.isError != isError else { return }
        context.coordinator.isError = isError
        let clip = scroll.contentView
        let wasAtEnd = clip.bounds.maxY >= (textView.frame.height - 24)
        textView.textStorage?.setAttributedString(NSAttributedString(string: shown, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
            .foregroundColor: text.isEmpty ? NSColor(IDEAppearance.ColorToken.muted) : color,
        ]))
        if wasAtEnd { textView.scrollToEndOfDocument(nil) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var isError: Bool?
    }
}
