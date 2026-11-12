import SwiftUI

/// The diff tab's status line: an error, a dirty notice, or the "2 of 5" counter.
struct IDEDiffToolbarStatus: View {
    let session: IDEDiffSession

    var body: some View {
        if let message = session.message {
            Text(message)
                .foregroundStyle(IDEAppearance.ColorToken.error)
                .lineLimit(1)
                .help(message)
        } else if let reason = session.readOnlyReason {
            Text(reason)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .lineLimit(1)
        } else if session.isRightDirty {
            Text("Edited, saved on ⌘S or when you leave the tab")
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .lineLimit(1)
        }
        counter
            .foregroundStyle(IDEAppearance.ColorToken.muted)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
    }

    private var counter: Text {
        switch session.state {
        case .loading: return Text("Loading…")
        case .binary, .failed: return Text("")
        case .ready: break
        }
        let count = session.chunks.count
        guard count > 0 else { return Text("No differences") }
        if let current = session.currentChunkIndex, current < count {
            return Text("\(current + 1) of ^[\(count) difference](inflect: true)")
        }
        return Text("^[\(count) difference](inflect: true)")
    }
}
