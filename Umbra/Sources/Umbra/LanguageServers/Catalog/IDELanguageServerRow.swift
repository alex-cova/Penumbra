import SwiftUI

struct IDELanguageServerRow: View {
    let spec: IDELanguageServerSpec
    let workspace: IDEWorkspace
    @AppStorage private var enabled: Bool
    @AppStorage private var path: String
    @State private var found: URL?
    @State private var version: String?
    @State private var searched = false
    @State private var showsInstall = false

    init(spec: IDELanguageServerSpec, workspace: IDEWorkspace) {
        self.spec = spec
        self.workspace = workspace
        _enabled = AppStorage(wrappedValue: true, spec.enabledDefaultsKey)
        _path = AppStorage(wrappedValue: "", spec.pathDefaultsKey)
    }

    private var phase: IDELanguageServerHost.Phase? {
        workspace.languageServerHost.statuses.first { $0.id == spec.id }?.phase
    }

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.snug) {
            HStack {
                Toggle(spec.displayName, isOn: $enabled)
                Spacer()
                Text(statusText).foregroundStyle(.secondary).font(.callout)
                Button("Restart", action: restart)
                    .disabled(!enabled || phase == nil && found == nil)
            }
            if enabled {
                LabeledContent(spec.executables[0]) {
                    TextField(found?.path ?? "Path (leave empty to search)", text: $path)
                        .textFieldStyle(.roundedBorder)
                }
                if let version { Text(version).font(.caption).foregroundStyle(.secondary) }
                if let error = workspace.languageServerHost.serverErrors[spec.id] {
                    Text(error).font(.caption.monospaced()).foregroundStyle(.red).lineLimit(6).textSelection(.enabled)
                }
                if searched, found == nil {
                    DisclosureGroup("How to install", isExpanded: $showsInstall) {
                        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
                            if let prerequisite = spec.prerequisite { Text("Needs: \(prerequisite)").font(.caption) }
                            ForEach(spec.installInstructions, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
                            Text("Licence: \(spec.licence)").font(.caption).foregroundStyle(.secondary)
                            if !spec.notes.isEmpty { Text(spec.notes).font(.caption).foregroundStyle(.secondary) }
                            if let url = URL(string: spec.installURL) { Link("Documentation", destination: url).font(.caption) }
                        }
                    }
                }
            }
        }
        .padding(.vertical, IDEAppearance.Spacing.xxs)
        .task(id: path) { await refresh() }
        .onChange(of: enabled) { _, isOn in
            guard let box = workspace.languageServerConnections[spec.id] else { return }
            let definition = IDECatalogServer.definition(for: spec)
            if isOn { workspace.languageServerHost.restart(definition, connection: box) } else { workspace.languageServerHost.stop(definition, connection: box) }
        }
    }

    private var statusText: String {
        if !enabled { return "Off" }
        switch phase {
        case .ready: return "Running"
        case .starting: return "Starting"
        case .restarting: return "Restarting"
        case .failed: return "Failed"
        case .untrusted: return "Not trusted"
        case .missing: return "Not installed"
        case .unprepared: return "Project not indexed"
        case .stopped: return "Stopped"
        case nil:
            guard searched else { return "" }
            return found == nil ? "Not installed" : "Installed"
        }
    }

    private func refresh() async {
        let login = await IDEServerLocator.loginShellPath()
        let process = IDEServerLocator.pathEntries(ProcessInfo.processInfo.environment["PATH"])
        let root = workspace.project.rootURL ?? FileManager.default.homeDirectoryForCurrentUser
        let located = IDEServerLocator.locate(
            spec: spec, root: root, override: path.isEmpty ? nil : path, searchPath: process + login
        )
        found = located
        searched = true
        if let located {
            version = await IDEServerVersion.read(spec: spec, executable: located, environment: nil)
        } else {
            version = nil
        }
    }

    private func restart() {
        guard let definition = IDELanguageServerCatalog.spec(id: spec.id).map({ IDECatalogServer.definition(for: $0) }),
              let box = workspace.languageServerConnections[spec.id] else { return }
        workspace.languageServerHost.restart(definition, connection: box)
    }
}
