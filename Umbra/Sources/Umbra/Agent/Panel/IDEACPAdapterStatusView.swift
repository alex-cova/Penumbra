import SwiftUI

/// The install/update progress or state line of one managed adapter row. Extracted from
/// `IDEACPAdaptersSection` so the section stays a composition of subviews.
struct IDEACPAdapterStatusView: View {
    let state: IDEACPAdapterManager.AdapterState

    var body: some View {
        switch state.phase {
        case .working(let step), .updating(_, _, let step):
            VStack(alignment: .leading, spacing: 2) {
                if let done = state.progress?.bytesDone, let total = state.progress?.bytesExpected, step == .downloading, total > 0 {
                    ProgressView(value: Double(min(done, total)), total: Double(total))
                        .accessibilityIdentifier(IDEACPAccessibility.progress(state.entry.id))
                        .accessibilityLabel("\(state.entry.name) install progress")
                        .accessibilityValue((Double(done) / Double(max(total, 1))).formatted(.percent))
                } else {
                    ProgressView().controlSize(.small)
                        .accessibilityIdentifier(IDEACPAccessibility.progress(state.entry.id))
                        .accessibilityLabel("\(state.entry.name) \(step.title)")
                }
                Text(progressText(state, step: step))
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .accessibilityIdentifier(IDEACPAccessibility.status(state.entry.id))
            }
        case .failed(let error, let keeping):
            VStack(alignment: .leading, spacing: 2) {
                Text(keeping.map { "Update failed. Still on \($0)." } ?? "Failed")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.error)
                Text(error.localizedDescription)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .ideAnnounces(error.localizedDescription)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(IDEACPAccessibility.status(state.entry.id))
        case .updateAvailable(_, let available, let security):
            Text(security
                 ? "Security update \(available) is available. The installed version has a published advisory."
                 : "Update \(available) is available.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(security ? Color.orange : IDEAppearance.ColorToken.muted)
                .accessibilityIdentifier(IDEACPAccessibility.status(state.entry.id))
                .ideAnnounces(security
                    ? "Security update \(available) is available for \(state.entry.name)."
                    : "Update \(available) is available for \(state.entry.name).")
        case .ready:
            Text(runningText ?? "Ready")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.run)
                .accessibilityIdentifier(IDEACPAccessibility.status(state.entry.id))
        case .notInstalled:
            Text(state.checkError?.localizedDescription ?? "Not installed.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(state.checkError == nil ? IDEAppearance.ColorToken.muted : Color.orange)
                .accessibilityIdentifier(IDEACPAccessibility.status(state.entry.id))
        case .disabled:
            Text("Disabled")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
    }

    private var runningText: String? {
        let uses = IDEACPAdapterManager.shared.runningUses(state.entry.id)
        return uses > 0 ? "Ready · used by \(uses) running chat\(uses == 1 ? "" : "s")" : nil
    }

    private func progressText(_ state: IDEACPAdapterManager.AdapterState, step: IDEACPAdapterStep) -> String {
        guard let progress = state.progress else { return step.title + "…" }
        if let done = progress.bytesDone, let total = progress.bytesExpected, step == .downloading {
            let format = { (bytes: Int64) in IDEACPByteFormat.string(bytes) }
            return "\(progress.detail) · \(format(done)) of about \(format(total))"
        }
        return progress.detail
    }
}
