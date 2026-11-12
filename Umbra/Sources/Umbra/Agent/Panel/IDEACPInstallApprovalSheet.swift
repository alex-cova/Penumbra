import SwiftUI

/// What the user approves before anything is downloaded.
struct IDEACPInstallApprovalSheet: View {
    let proposal: IDEACPInstallProposal
    let onApprove: () -> Void
    let onCancel: () -> Void

    private var isUpdate: Bool { proposal.updatingFrom != nil }
    private var name: String { IDEACPAdapterCatalog.entry(id: proposal.entryID)?.name ?? proposal.entryID }

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.md) {
            Text(isUpdate ? "Update \(name) adapter" : "Install \(name) adapter")
                .font(IDEAppearance.Typography.titlebarTitle)
                .accessibilityAddTraits(.isHeader)
            if proposal.isSecurityUpdate {
                Text("The installed version has a published security advisory.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(Color.orange)
            }
            Grid(alignment: .topLeading, horizontalSpacing: IDEAppearance.Spacing.md, verticalSpacing: IDEAppearance.Spacing.xs) {
                row("Adapter", "\(proposal.packageName)@\(proposal.version)" + (proposal.updatingFrom.map { " (from \($0))" } ?? ""))
                row("Provider", proposal.providerName)
                row("Publisher", proposal.publisher)
                row("Source", "registry.npmjs.org")
                row("Method", proposal.method)
                row("Requires", "\(proposal.nodeVersionRequirement.map { "Node.js \($0)" } ?? "Node.js"). \(proposal.nodeDescription)")
                row("Size", "About \(ByteCountFormatter.string(fromByteCount: proposal.approximateBytes, countStyle: .file)) on disk, including the \(name) engine. \(ByteCountFormatter.string(fromByteCount: proposal.freeBytes, countStyle: .file)) free.")
                row("Checked", "Registry signature verified with a key built into Umbra (\(proposal.signatureKeyID.suffix(12))…). Build provenance names \(proposal.repository.replacing("https://", with: "")). npm re-checks signatures after the download.")
            }
            .font(IDEAppearance.Typography.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(proposal.warnings, id: \.self) { warning in
                Text("⚠︎ \(warning)")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("It installs into Umbra's own folder and never changes your global npm packages or shell. After verification Umbra starts the adapter once to check that it speaks ACP, then makes \(name) available in the Agent panel. Approving also allows Umbra to run it when you choose it.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(IDEACPAccessibility.approvalCancel)
                Button(isUpdate ? "Update" : "Install", action: onApprove)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(IDEACPAccessibility.approvalConfirm)
            }
        }
        .padding(IDEAppearance.Spacing.lg)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(IDEACPAccessibility.approval)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .gridColumnAlignment(.trailing)
            Text(value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(label == "Adapter" ? IDEACPAccessibility.approvalPackage : "acp.approval.\(label.lowercased())")
        .accessibilityLabel("\(label): \(value)")
    }
}
