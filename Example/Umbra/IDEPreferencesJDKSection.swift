import AppKit
import JavaIntelligence
import SwiftUI

/// Settings › Java › JDKs: the installed JDKs (detected, plus the ones added by hand), the default
/// for every project, and Add / Remove / Rescan. A project's own choice is made from the status bar
/// and overrides the default.
struct IDEPreferencesJDKSection: View {
    @Environment(IDEWorkspace.self) private var workspace
    @State private var pendingRemoval: JDKInstallation?
    private var jdk: IDEJDKSelection { workspace.javaSupport.jdk }

    var body: some View {
        IDESettingsSection(
            "JDKs",
            footer: "Found through java_home, /Library/Java/JavaVirtualMachines, SDKMAN, Gradle, Homebrew, asdf, jenv and mise. A project's own choice, made from the JDK item in the status bar, overrides the default. Automatic picks the closest installed JDK at or above the project's Java level."
        ) {
            IDESettingsPicker("Default JDK", selection: defaultBinding) {
                Text("Automatic").tag(String?.none)
                ForEach(jdk.detected, id: \.home) { installation in
                    Text(installation.displayName).tag(Optional(installation.home.resolvingSymlinksInPath().path))
                }
            }

            if jdk.detected.isEmpty {
                Text(jdk.isScanning ? "Looking for JDKs…" : "No JDK found. Add one with Add JDK…")
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(jdk.detected.enumerated()), id: \.element.home) { index, installation in
                        if index > 0 {
                            Divider().overlay(IDEAppearance.ColorToken.border)
                        }
                        row(for: installation)
                            .padding(.vertical, IDEAppearance.Spacing.sm)
                    }
                }
                .padding(.horizontal, IDEAppearance.Spacing.md)
                .background(
                    IDEAppearance.ColorToken.workbench,
                    in: RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous)
                )
            }

            HStack {
                Button("Add JDK…") {
                    workspace.addJDKFromPanel()
                }
                Button("Rescan") {
                    Task { await jdk.refreshDetected() }
                }
                .disabled(jdk.isScanning)
                if jdk.isScanning {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
            }
        }
        .task { await jdk.refreshDetected() }
        .confirmationDialog(
            "Remove \(pendingRemoval?.displayName ?? "JDK")?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { installation in
            Button("Remove", role: .destructive) {
                jdk.removeJDK(installation)
            }
        } message: { installation in
            Text(removalMessage(for: installation))
        }
    }

    private func row(for installation: JDKInstallation) -> some View {
        let missing = jdk.isMissing(installation)
        return HStack(alignment: .firstTextBaseline, spacing: IDEAppearance.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: IDEAppearance.Spacing.xs) {
                    Text(installation.displayName)
                        .foregroundStyle(IDEAppearance.ColorToken.foreground)
                    ForEach(badges(for: installation, missing: missing), id: \.self) { badge in
                        Text(badge)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(IDEAppearance.ColorToken.card, in: Capsule())
                            .foregroundStyle(IDEAppearance.ColorToken.muted)
                    }
                }
                Text(installation.home.path)
                    .font(IDEAppearance.Typography.monoCaption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: IDEAppearance.Spacing.sm)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([installation.home])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal \(installation.displayName) in Finder")
            .disabled(missing)
            if jdk.isUserAdded(installation) {
                Button {
                    remove(installation)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove from the list")
                .accessibilityLabel("Remove \(installation.displayName)")
            }
        }
        .contextMenu {
            Button("Use as Default") { jdk.chooseAsDefault(installation) }
                .disabled(jdk.isDefault(installation))
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([installation.home])
            }
            .disabled(missing)
            if jdk.isUserAdded(installation) {
                Divider()
                Button("Remove…") { remove(installation) }
            }
        }
    }

    private func badges(for installation: JDKInstallation, missing: Bool) -> [String] {
        var badges: [String] = []
        if jdk.isDefault(installation) { badges.append("Default") }
        if jdk.isInUse(installation) { badges.append("In use") }
        if jdk.isUserAdded(installation) { badges.append("Added by you") }
        if !installation.isFullJDK && !missing { badges.append("JRE only") }
        if missing { badges.append("Missing") }
        return badges
    }

    private func remove(_ installation: JDKInstallation) {
        let usage = jdk.usage(of: installation)
        if usage.isDefault || !usage.projects.isEmpty {
            pendingRemoval = installation
        } else {
            jdk.removeJDK(installation)
        }
    }

    private func removalMessage(for installation: JDKInstallation) -> String {
        let usage = jdk.usage(of: installation)
        var users: [String] = []
        if usage.isDefault { users.append("the default JDK") }
        if !usage.projects.isEmpty {
            users.append("the JDK of \(usage.projects.count) project\(usage.projects.count == 1 ? "" : "s")")
        }
        return "It is \(users.joined(separator: " and ")). Those fall back to Automatic. The JDK's files are not touched."
    }

    /// The default JDK's resolved home path, `nil` for Automatic.
    private var defaultBinding: Binding<String?> {
        Binding {
            jdk.selection.global?.resolvingSymlinksInPath().path
        } set: { path in
            let installation = path.flatMap { path in
                jdk.detected.first { $0.home.resolvingSymlinksInPath().path == path }
            }
            jdk.chooseAsDefault(installation)
        }
    }
}
