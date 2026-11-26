import AppKit
import GitIntelligence
import Observation
import SwiftUI

/// What the popover can do with the commit it describes.
struct IDEBlameCommitActions {
    var showDiff: () -> Void
    var showInLog: () -> Void
    var copyRevision: () -> Void
    var openOnWeb: () -> Void
}

@MainActor
@Observable
final class IDEBlameCommitModel {
    let line: GitBlameLine
    /// The message after its subject; empty until it has loaded, and for a one-line message.
    var messageBody = ""
    @ObservationIgnored var isPointerInside = false

    init(line: GitBlameLine) {
        self.line = line
    }
}

/// The popover over a blame annotation: the commit's author, dates, message and the actions on it
/// (IntelliJ's annotation hover). It stays while the pointer is over it, so its buttons can be reached.
@MainActor
final class IDEBlameCommitPopover: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    private var model: IDEBlameCommitModel?
    private var closeTask: Task<Void, Never>?
    private var bodyTask: Task<Void, Never>?
    /// The annotation the popover shows.
    private(set) var presentedHash: String?
    var onClose: (() -> Void)?

    var isShown: Bool { popover?.isShown == true }

    func present(
        line: GitBlameLine, rect: CGRect, of view: NSView,
        actions: IDEBlameCommitActions, loadBody: @escaping () async -> String?
    ) {
        closeTask?.cancel()
        if presentedHash == line.hash, isShown { return }
        close(notify: false)
        let model = IDEBlameCommitModel(line: line)
        self.model = model
        presentedHash = line.hash
        let popover = NSPopover()
        // Not `.transient`: it stays up while the pointer wanders to its buttons, and goes when
        // the pointer leaves both (``scheduleClose()``).
        popover.behavior = .semitransient
        popover.animates = false
        popover.delegate = self
        let content = IDEBlameCommitPopoverView(
            model: model, actions: actions,
            onPointer: { [weak self, weak model] inside in
                model?.isPointerInside = inside
                if inside { self?.closeTask?.cancel() } else { self?.scheduleClose() }
            })
        popover.contentViewController = NSHostingController(rootView: content.preferredColorScheme(IDEAppearance.preferredColorScheme))
        self.popover = popover
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxX)
        bodyTask?.cancel()
        bodyTask = Task { [weak model] in
            let body = await loadBody()
            guard !Task.isCancelled, let model else { return }
            model.messageBody = body ?? ""
        }
    }

    /// The pointer left the annotation: close after a moment unless it went into the popover.
    func scheduleClose(after delay: Duration = .milliseconds(350)) {
        closeTask?.cancel()
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.model?.isPointerInside != true else { return }
            self.close()
        }
    }

    func close(notify: Bool = true) {
        closeTask?.cancel()
        bodyTask?.cancel()
        let wasShown = popover != nil
        popover?.close()
        popover = nil
        model = nil
        presentedHash = nil
        if wasShown && notify { onClose?() }
    }

    func popoverDidClose(_ notification: Notification) {
        guard popover != nil else { return }
        popover = nil
        model = nil
        presentedHash = nil
        onClose?()
    }
}

private struct IDEBlameCommitPopoverView: View {
    let model: IDEBlameCommitModel
    let actions: IDEBlameCommitActions
    let onPointer: (Bool) -> Void

    private var line: GitBlameLine { model.line }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Button(action: actions.showInLog) {
                    Text(line.shortHash).font(.system(.body, design: .monospaced))
                }
                .buttonStyle(.link)
                .help("Show in the log")
                Text(line.author).fontWeight(.semibold)
                if !line.authorEmail.isEmpty {
                    Text("<\(line.authorEmail)>").foregroundStyle(.secondary)
                }
            }
            Text(dates).font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(line.summary).textSelection(.enabled)
                if !model.messageBody.isEmpty {
                    Text(model.messageBody)
                        .font(.callout).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            HStack(spacing: 14) {
                Button("Show Diff", action: actions.showDiff)
                Button("Show in Log", action: actions.showInLog)
                Button("Copy Revision", action: actions.copyRevision)
                Button("Open on Web", action: actions.openOnWeb)
            }
            .buttonStyle(.link)
            .font(.callout)
        }
        .padding(12)
        .frame(width: 380, alignment: .leading)
        .onHover(perform: onPointer)
    }

    private var dates: String {
        let author = line.date.formatted(date: .abbreviated, time: .shortened)
        let sameCommitter = line.committer.isEmpty || (line.committer == line.author && line.committerDate == line.date)
        guard !sameCommitter else { return author }
        let committed = line.committerDate.formatted(date: .abbreviated, time: .shortened)
        return "\(author) · committed by \(line.committer), \(committed)"
    }
}
