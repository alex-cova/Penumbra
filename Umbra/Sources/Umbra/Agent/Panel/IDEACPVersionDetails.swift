import SwiftUI

/// The expandable version list of one managed adapter row: installed versions, publisher and
/// signature lines, diagnostics. Extracted from `IDEACPAdaptersSection`.
struct IDEACPVersionDetails: View {
    let state: IDEACPAdapterManager.AdapterState
    @Binding var messages: [String: String]

    private let manager = IDEACPAdapterManager.shared

    var body: some View {
        let entry = state.entry
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            Text("Versions on this Mac")
                .font(IDEAppearance.Typography.sectionHeader)
            if state.versions.isEmpty {
                Text("None installed.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            ForEach(state.versions) { manifest in
                let isActive = manifest.version == state.activeVersion
                let inUse = manager.isInUse(entry.id, version: manifest.version)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(manifest.version + (isActive ? " · active" : "") + (inUse ? " · in use" : ""))
                        Spacer()
                        if !isActive {
                            Button("Make Active") { makeActive(entry.id, manifest.version) }
                                .disabled(state.phase.isBusy)
                                .accessibilityLabel("Make \(entry.name) \(manifest.version) active")
                                .accessibilityIdentifier(IDEACPAccessibility.activateVersion(entry.id, manifest.version))
                            Button("Remove") { removeVersion(entry.id, manifest.version) }
                                .disabled(inUse || state.phase.isBusy)
                                .help(inUse ? "A running chat is using this version." : "Delete this version")
                                .accessibilityLabel("Remove \(entry.name) \(manifest.version)")
                                .accessibilityIdentifier(IDEACPAccessibility.removeVersion(entry.id, manifest.version))
                        }
                    }
                    Text("Installed \(manifest.installedAt.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: manifest.installedBytes, countStyle: .file)) · Node.js \(manifest.nodeVersion)")
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                    Text("Publisher: \(manifest.publisher)")
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                    Text("Registry key \(manifest.signatureKeyID) · entry sha256 \(manifest.entrySHA256.prefix(12))…")
                        .font(IDEAppearance.Typography.monoSmall)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                    ForEach(manifest.warnings, id: \.self) { warning in
                        Text("⚠︎ \(warning)")
                            .font(IDEAppearance.Typography.caption)
                            .foregroundStyle(Color.orange)
                    }
                }
                .font(IDEAppearance.Typography.caption)
            }
            if !state.diagnostics.isEmpty {
                DisclosureGroup("Diagnostics") {
                    ScrollView {
                        Text(state.diagnostics)
                            .font(IDEAppearance.Typography.monoSmall)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
                .font(IDEAppearance.Typography.caption)
            }
        }
        .padding(.leading, 28)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(IDEACPAccessibility.versions(entry.id))
    }

    private func makeActive(_ id: String, _ version: String) {
        Task {
            do { try await manager.makeActive(id, version: version) } catch {
                messages[id] = IDEACPAdapterManager.normalize(error).localizedDescription
            }
        }
    }

    private func removeVersion(_ id: String, _ version: String) {
        var alert = IDEAlert.confirm(
            "Remove version \(version)?", detail: "The files for this version are deleted. The active version is not changed.",
            confirm: "Remove", isDestructive: true)
        guard alert.confirms() else { return }
        Task {
            do { try await manager.removeVersion(id, version: version) } catch {
                messages[id] = IDEACPAdapterManager.normalize(error).localizedDescription
            }
        }
    }
}
