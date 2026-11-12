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
            let nativeEntries = IDEACPAdapterCatalog.entries.filter { !$0.isManaged }
            ForEach(nativeEntries) { entry in
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
        @Bindable var manager = manager
        return VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xxs) {
            HStack {
                Picker("Check for updates", selection: $manager.updatePolicy) {
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
            IDEACPAdapterStatusView(state: state)
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
            if detailsOpen.contains(entry.id) { IDEACPVersionDetails(state: state, messages: $messages) }
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
                Label("More actions for \(entry.name)", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .labelStyle(.iconOnly)
            .fixedSize()
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
                    Button("Add", action: { addPreset(entry) })
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

    private func addPreset(_ entry: IDEACPAdapterEntry) {
        guard let preset = IDEACPRegistry.preset(id: entry.presetID) else { return }
        _ = settings.materializePreset(preset)
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
