import SwiftUI

/// Settings ▸ Agent ▸ Adapters. Installs, updates, verifies and removes the ACP adapters Umbra
/// manages itself, and shows the agents that ship their own ACP mode. Every button does the real
/// operation; installing needs the user's approval on the sheet first.
struct IDEACPAdaptersSection: View {
    let settings: IDEAgentSettings
    var agent: IDEAgentController?

    private let manager = IDEACPAdapterManager.shared

    @State private var proposal: IDEACPInstallProposal?
    @State private var preparing: Set<String> = []
    @State private var messages: [String: String] = [:]
    @State private var detailsOpen: Set<String> = []
    @State private var customEditing: String?
    @State private var customCommand = ""

    var body: some View {
        Section {
            Text("Claude Code and Codex need a small adapter to speak the Agent Client Protocol. Umbra installs it in its own folder, checks who published it, and keeps earlier versions so you can go back. Nothing is installed or updated without your approval, and nothing touches your global npm packages.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            if manager.isSandboxed {
                banner(
                    "Managed installs are not available in the App Store build, which cannot run npm. Use a custom executable under Agents below.",
                    identifier: IDEACPAccessibility.adaptersSandbox)
            } else if manager.node == .missing {
                banner(
                    IDEACPAdapterError.nodeMissing.localizedDescription ?? "Node.js was not found.",
                    identifier: IDEACPAccessibility.adaptersNode)
            }
            if manager.states.values.contains(where: { if case .offline? = $0.checkError { true } else { false } }) {
                banner(
                    "You appear to be offline. Umbra cannot check for updates or install adapters until the network is back. Installed adapters keep working.",
                    identifier: IDEACPAccessibility.adaptersOffline)
            }
            updatesRow
            if manager.hasLoaded {
                ForEach(IDEACPAdapterCatalog.managedEntries) { entry in
                    if let state = manager.states[entry.id] { managedRow(state) }
                }
            } else {
                HStack(spacing: IDEAppearance.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("Reading installed adapters…")
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(IDEACPAccessibility.adaptersLoading)
            }
            ForEach(IDEACPAdapterCatalog.entries.filter { !$0.isManaged }) { entry in
                nativeRow(entry)
            }
        } header: {
            Text("Adapters")
                .accessibilityIdentifier(IDEACPAccessibility.adapters)
        }
        .task {
            await manager.load()
            await settings.refreshACPPath()
            await manager.refreshNode()
            await manager.checkIfDue()
        }
        .sheet(item: $proposal) { item in
            IDEACPInstallApprovalSheet(
                proposal: item,
                onApprove: {
                    proposal = nil
                    manager.install(item, settings: settings)
                },
                onCancel: { proposal = nil })
        }
    }

    // MARK: - Updates

    private var updatesRow: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xxs) {
            HStack {
                Picker("Check for updates", selection: Binding(
                    get: { manager.updatePolicy }, set: { manager.updatePolicy = $0 })
                ) {
                    ForEach(IDEACPUpdateCheckPolicy.allCases) { Text($0.title).tag($0) }
                }
                .disabled(manager.isSandboxed)
                .accessibilityLabel("Check for updates")
                .accessibilityIdentifier(IDEACPAccessibility.updatePolicy)
                Button(manager.isChecking ? "Checking…" : "Check Now") {
                    Task { await manager.checkForUpdates() }
                }
                .disabled(manager.isChecking || manager.isSandboxed)
                .accessibilityLabel("Check for adapter updates now")
                .accessibilityIdentifier(IDEACPAccessibility.checkUpdates)
            }
            Text(lastCheckedText + " · Checking reads the registry's version list only; it never downloads or runs anything.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
        .accessibilityElement(children: .contain)
    }

    private var lastCheckedText: String {
        guard let date = manager.lastChecked else { return "Not checked yet" }
        return "Last checked \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    // MARK: - Managed adapters

    @ViewBuilder private func managedRow(_ state: IDEACPAdapterManager.AdapterState) -> some View {
        let entry = state.entry
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            HStack(alignment: .top) {
                Image(systemName: entry.symbol)
                    .frame(width: 20)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                    Text("\(entry.provider) · \(entry.npm?.package ?? entry.id)")
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
                Spacer()
                actions(for: state)
            }
            Text(versionLine(state))
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            statusView(state)
            if let message = messages[entry.id] {
                HStack(alignment: .top) {
                    Text(message)
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.error)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(IDEACPAccessibility.message(entry.id))
                        .ideAnnounces(message)
                    Spacer()
                    Button("Dismiss") { messages[entry.id] = nil }
                        .font(IDEAppearance.Typography.caption)
                }
            }
            if let definition = definition(for: entry) {
                readinessLine(definition, adapterID: entry.id)
            }
            if customEditing == entry.id { customEditor(entry) }
            if detailsOpen.contains(entry.id) { versionDetails(state) }
        }
        .padding(.vertical, IDEAppearance.Spacing.xxs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(IDEACPAccessibility.adapter(entry.id))
        .accessibilityLabel("\(entry.name) adapter, \(state.phase.title)")
    }

    private func versionLine(_ state: IDEACPAdapterManager.AdapterState) -> String {
        var parts: [String] = []
        parts.append("Installed: \(state.activeVersion ?? "none")")
        if let available = state.available {
            parts.append("Available: \(available)")
        } else if state.checkError != nil {
            parts.append("Available: unknown (offline)")
        } else {
            parts.append("Available: not checked")
        }
        if state.activeVersion != nil, let manifest = state.activeManifest {
            parts.append("Node.js \(manifest.nodeVersion)")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func statusView(_ state: IDEACPAdapterManager.AdapterState) -> some View {
        switch state.phase {
        case .working(let step), .updating(_, _, let step):
            VStack(alignment: .leading, spacing: 2) {
                if let done = state.progress?.bytesDone, let total = state.progress?.bytesExpected, step == .downloading, total > 0 {
                    ProgressView(value: Double(min(done, total)), total: Double(total))
                        .accessibilityIdentifier(IDEACPAccessibility.progress(state.entry.id))
                        .accessibilityLabel("\(state.entry.name) install progress")
                        .accessibilityValue("\(done * 100 / total) percent")
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
            Text(runningText(state.entry.id) ?? "Ready")
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

    private func progressText(_ state: IDEACPAdapterManager.AdapterState, step: IDEACPAdapterStep) -> String {
        guard let progress = state.progress else { return step.title + "…" }
        if let done = progress.bytesDone, let total = progress.bytesExpected, step == .downloading {
            let format = { (bytes: Int64) in IDEACPByteFormat.string(bytes) }
            return "\(progress.detail) · \(format(done)) of about \(format(total))"
        }
        return progress.detail
    }

    private func runningText(_ id: String) -> String? {
        let uses = manager.runningUses(id)
        return uses > 0 ? "Ready · used by \(uses) running chat\(uses == 1 ? "" : "s")" : nil
    }

    @ViewBuilder private func readinessLine(_ definition: IDEACPDefinition, adapterID: String) -> some View {
        let text = readiness(of: definition)
        Text(text.title)
            .font(IDEAppearance.Typography.caption)
            .foregroundStyle(text.color)
            .accessibilityIdentifier(IDEACPAccessibility.connection(adapterID))
            .accessibilityLabel("Connection: \(text.title)")
    }

    private func readiness(of definition: IDEACPDefinition) -> (title: String, color: Color) {
        let live = agent?.conversations.contains {
            $0.resolvedACPAgentID == definition.id && $0.acpLiveState == .connected
        } ?? false
        if live { return ("Connection: connected in a chat", IDEAppearance.ColorToken.run) }
        switch settings.acpProbes[definition.id]?.phase {
        case .running: return ("Connection: testing…", IDEAppearance.ColorToken.muted)
        case .connected(let version, let name, let load)?:
            let who = name.map { "\($0), " } ?? ""
            return ("Connection: OK · \(who)ACP \(version)" + (load ? ", can resume chats" : ""), IDEAppearance.ColorToken.run)
        case .authenticationRequired(let method)?:
            return ("Connection: starts, sign-in needed · \(method)", Color.orange)
        case .failed(let message)?:
            return ("Connection: \(message)", IDEAppearance.ColorToken.error)
        case nil:
            return ("Connection: not tested", IDEAppearance.ColorToken.muted)
        }
    }

    // MARK: - Actions

    @ViewBuilder private func actions(for state: IDEACPAdapterManager.AdapterState) -> some View {
        let entry = state.entry
        HStack(spacing: IDEAppearance.Spacing.sm) {
            switch state.phase {
            case .notInstalled:
                Button(preparing.contains(entry.id) ? "Checking…" : "Install…") { prepare(entry) }
                    .disabled(manager.isSandboxed || preparing.contains(entry.id))
                    .accessibilityLabel("Install \(entry.name) adapter")
                    .accessibilityIdentifier(IDEACPAccessibility.install(entry.id))
            case .working, .updating:
                Button("Cancel") { manager.cancel(entry.id) }
                    .accessibilityLabel("Cancel installing \(entry.name)")
                    .accessibilityIdentifier(IDEACPAccessibility.cancel(entry.id))
            case .updateAvailable:
                Button(preparing.contains(entry.id) ? "Checking…" : "Update…") { prepare(entry) }
                    .disabled(preparing.contains(entry.id))
                    .accessibilityLabel("Update \(entry.name) adapter")
                    .accessibilityIdentifier(IDEACPAccessibility.update(entry.id))
                testButton(entry)
            case .failed(_, let keeping):
                Button(preparing.contains(entry.id) ? "Checking…" : "Retry") { prepare(entry) }
                    .disabled(preparing.contains(entry.id))
                    .accessibilityLabel("Retry \(entry.name)")
                    .accessibilityIdentifier(IDEACPAccessibility.retry(entry.id))
                if keeping != nil { testButton(entry) }
            case .ready:
                testButton(entry)
            case .disabled:
                EmptyView()
            }
            Menu {
                menuItems(for: state)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions for \(entry.name)")
            .accessibilityIdentifier(IDEACPAccessibility.more(entry.id))
        }
        .font(IDEAppearance.Typography.caption)
    }

    @ViewBuilder private func menuItems(for state: IDEACPAdapterManager.AdapterState) -> some View {
        let entry = state.entry
        Button(detailsOpen.contains(entry.id) ? "Hide Version Details" : "Version Details") {
            if detailsOpen.contains(entry.id) { detailsOpen.remove(entry.id) } else { detailsOpen.insert(entry.id) }
        }
        .accessibilityIdentifier(IDEACPAccessibility.details(entry.id))
        Button("Restore Previous Version") { restorePrevious(entry.id) }
            .disabled(state.previousVersion == nil || state.phase.isBusy)
            .accessibilityIdentifier(IDEACPAccessibility.restore(entry.id))
        Button("Show in Finder") { manager.reveal(entry.id) }
        Divider()
        if let definition = definition(for: entry) {
            if definition.launchMode == .auto {
                Button("Use Custom Executable…") {
                    customCommand = definition.commandLine
                    customEditing = entry.id
                }
            } else {
                Button("Use the Adapter Umbra Manages") { settings.useCatalogLaunch(id: definition.id) }
            }
        }
        if case .failed = state.phase {
            Button("Dismiss Error") { manager.acknowledgeFailure(entry.id) }
        }
        Divider()
        Button("Remove Adapter…", role: .destructive) { confirmRemove(entry) }
            .disabled(state.versions.isEmpty || state.phase.isBusy)
            .accessibilityIdentifier(IDEACPAccessibility.remove(entry.id))
    }

    private func testButton(_ entry: IDEACPAdapterEntry) -> some View {
        Button("Test Connection") { test(entry) }
            .disabled(isTesting(entry))
            .accessibilityLabel("Test \(entry.name) connection")
            .accessibilityIdentifier(IDEACPAccessibility.test(entry.id))
    }

    // MARK: - Version details

    @ViewBuilder private func versionDetails(_ state: IDEACPAdapterManager.AdapterState) -> some View {
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

    // MARK: - Custom executable

    @ViewBuilder private func customEditor(_ entry: IDEACPAdapterEntry) -> some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            TextField("Command", text: $customCommand)
                .font(IDEAppearance.Typography.monoSmall)
                .accessibilityLabel("Custom executable for \(entry.name)")
            Text("Umbra runs exactly this instead of its own adapter. It is not verified.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            HStack {
                Button("Save") {
                    if let definition = definition(for: entry),
                       settings.updateACPAgent(id: definition.id, name: definition.name, commandLine: customCommand) {
                        customEditing = nil
                    }
                }
                .disabled(IDEACPDefinition.parseCommandLine(customCommand.trimmingCharacters(in: .whitespaces)) == nil)
                Button("Cancel") { customEditing = nil }
            }
        }
        .padding(.leading, 28)
    }

    // MARK: - Native CLIs

    @ViewBuilder private func nativeRow(_ entry: IDEACPAdapterEntry) -> some View {
        let definition = definition(for: entry)
        let probe = IDEACPDefinition(
            name: entry.name, command: nativeCommand(entry).command, args: nativeCommand(entry).args,
            presetID: entry.presetID, launchMode: .auto)
        let found = manager.resolution(for: probe, pathValue: settings.acpPathValue).launch
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            HStack(alignment: .top) {
                Image(systemName: entry.symbol)
                    .frame(width: 20)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                    Text("\(entry.provider) · built-in ACP mode: \(([nativeCommand(entry).command] + nativeCommand(entry).args).joined(separator: " "))")
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
                Spacer()
                if definition == nil {
                    Button("Add") { if let preset = IDEACPRegistry.preset(id: entry.presetID) { settings.materializePreset(preset) } }
                        .font(IDEAppearance.Typography.caption)
                        .accessibilityLabel("Add \(entry.name) to Agents")
                } else if found != nil {
                    testButton(entry)
                        .font(IDEAppearance.Typography.caption)
                }
            }
            Text(found.map { "Found at \($0.executable). Umbra does not install or update \(entry.name)." }
                 ?? "Not found on PATH. Install \(entry.name) from its publisher; Umbra does not install it.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(found == nil ? IDEAppearance.ColorToken.muted : IDEAppearance.ColorToken.run)
            if let definition { readinessLine(definition, adapterID: entry.id) }
        }
        .padding(.vertical, IDEAppearance.Spacing.xxs)
        .accessibilityElement(children: .contain)
    }

    private func nativeCommand(_ entry: IDEACPAdapterEntry) -> (command: String, args: [String]) {
        if case .nativeCLI(let command, let args) = entry.kind { return (command, args) }
        return (entry.id, [])
    }

    // MARK: - Operations

    private func definition(for entry: IDEACPAdapterEntry) -> IDEACPDefinition? {
        settings.acpAgents.first { $0.presetID == entry.presetID }
    }

    private func banner(_ text: String, identifier: String) -> some View {
        Text(text)
            .font(IDEAppearance.Typography.caption)
            .foregroundStyle(Color.orange)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Notice: \(text)")
            .accessibilityIdentifier(identifier)
            .ideAnnounces(text)
    }

    private func prepare(_ entry: IDEACPAdapterEntry) {
        messages[entry.id] = nil
        preparing.insert(entry.id)
        Task {
            defer { preparing.remove(entry.id) }
            do {
                proposal = try await manager.prepareInstall(entry.id)
            } catch {
                messages[entry.id] = IDEACPAdapterManager.normalize(error).localizedDescription
            }
        }
    }

    private func isTesting(_ entry: IDEACPAdapterEntry) -> Bool {
        guard let definition = definition(for: entry) else { return false }
        return settings.acpProbes[definition.id]?.phase == .running
    }

    private func test(_ entry: IDEACPAdapterEntry) {
        let definition: IDEACPDefinition
        if let existing = self.definition(for: entry) {
            definition = existing
        } else if let adopted = settings.adoptManagedAdapter(entry) {
            definition = adopted
        } else {
            return
        }
        if !settings.acpAllowedAgentIDs.contains(definition.id) {
            var alert = IDEAlert.confirm(
                "Allow “\(definition.displayName)” to run?",
                detail: "Test starts the agent, checks the ACP handshake, and then quits the process.",
                confirm: "Allow and Test")
            guard alert.confirms() else { return }
            settings.setACPAllowed(true, agentID: definition.id)
        }
        Task {
            let environment: [String: String]
            if let fromHost = await agent?.host?.agentCommandEnvironment() {
                environment = fromHost
            } else {
                let login = await IDELoginShellPath.shared.entries()
                environment = AgentCommandEnvironment.make(javaHome: nil, loginPath: login)
            }
            await manager.testConnection(definition: definition, settings: settings, environment: environment)
        }
    }

    private func restorePrevious(_ id: String) {
        Task {
            do { try await manager.restorePrevious(id) } catch {
                messages[id] = IDEACPAdapterManager.normalize(error).localizedDescription
            }
        }
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

    private func confirmRemove(_ entry: IDEACPAdapterEntry) {
        let uses = manager.runningUses(entry.id)
        if uses > 0 {
            var notice = IDEAlert.notice(
                "\(entry.name) is in use",
                detail: "\(uses) running chat\(uses == 1 ? " uses" : "s use") this adapter. Stop \(uses == 1 ? "it" : "them") first. Nothing was removed.")
            notice.runModal()
            return
        }
        var alert = IDEAlert.confirm(
            "Remove the \(entry.name) adapter?",
            detail: "Every version Umbra installed for it is deleted. Your \(entry.name) login and settings are not touched, and you can install it again later.",
            confirm: "Remove", isDestructive: true)
        guard alert.confirms() else { return }
        Task {
            do { try await manager.remove(entry.id) } catch {
                messages[entry.id] = IDEACPAdapterManager.normalize(error).localizedDescription
            }
        }
    }
}

// MARK: - Approval

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
                row("Checked", "Registry signature verified with a key built into Umbra (\(proposal.signatureKeyID.suffix(12))…). Build provenance names \(proposal.repository.replacingOccurrences(of: "https://", with: "")). npm re-checks signatures after the download.")
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

/// File sizes for the adapter UI, written as numbers ("0 bytes", never "Zero KB").
enum IDEACPByteFormat {
    static func string(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }
}
