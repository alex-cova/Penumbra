import AppKit
import JavaIntelligence
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Inspections: the active inspection profile (the project's own, or a global one),
/// every Java inspection by group with an on/off checkbox, a severity and per-scope exceptions.
/// Only deviations from a rule's default are stored in the profile.
struct IDEPreferencesInspectionsPane: View {
    @Bindable var preferences: IDEPreferences
    @Environment(IDEWorkspace.self) private var workspace
    @State private var query = ""
    @State private var filter: RuleFilter = .all
    @State private var expandedScopes: Set<String> = []
    @State private var prompt: NamePrompt?
    @State private var promptText = ""
    @State private var message: String?

    private enum RuleFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case modified = "Modified"
        case hasFix = "Has Quick Fix"
        case projectWide = "Project-Wide"
        var id: String { rawValue }
    }

    private enum NamePrompt: Identifiable {
        case duplicate, rename, copyToGlobal, new
        var id: Self { self }
        var title: String {
            switch self {
            case .duplicate: "Duplicate Profile"
            case .rename: "Rename Profile"
            case .copyToGlobal: "Save Project Profile as"
            case .new: "New Empty Profile"
            }
        }
    }

    private var inspections: IDEWorkspaceInspections { workspace.inspections }
    private var store: IDEInspectionProfiles { inspections.store }
    private var profile: JavaInspectionProfile { inspections.activeProfile }

    private var matchingRules: [JavaInspectionRule] {
        let query = query.trimmingCharacters(in: .whitespaces)
        let profile = profile
        return JavaInspectionRule.allCases.filter { rule in
            switch filter {
            case .all: break
            case .modified: if !profile.isModified(rule) { return false }
            case .hasFix: if !rule.hasQuickFix { return false }
            case .projectWide: if !JavaInspectionRule.projectWideRules.contains(rule) { return false }
            }
            guard !query.isEmpty else { return true }
            return rule.title.localizedCaseInsensitiveContains(query)
                || rule.summary.localizedCaseInsensitiveContains(query)
                || rule.code.localizedCaseInsensitiveContains(query)
                || rule.group.title.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        IDESettingsSection(
            "Inspection Profile",
            footer: "A project can carry its own profile in .umbra/inspections.json, shared through version control. Silence one place with a quick fix (Suppress for method or class), or a comment: //noinspection <id>."
        ) {
            profileBar
            HStack(spacing: IDEAppearance.Spacing.md) {
                TextField("Filter inspections", text: $query)
                    .textFieldStyle(.roundedBorder)
                Picker("Show", selection: $filter) {
                    ForEach(RuleFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 140)
                Toggle("Treat public API as used", isOn: publicApiBinding)
                    .toggleStyle(.checkbox)
                    .help("Unused declaration, weaker access, void return and constant parameter checks skip public and protected members")
            }
            if let message {
                Text(message)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
        }
        .onAppear {
            store.reload()
            focusRequestedRule()
        }
        .onChange(of: inspections.focusedRuleCode) { _, _ in focusRequestedRule() }
        .alert(prompt?.title ?? "", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })) {
            TextField("Name", text: $promptText)
            Button("OK") { commitPrompt() }
            Button("Cancel", role: .cancel) { prompt = nil }
        }

        let rules = matchingRules
        ForEach(JavaInspectionGroup.allCases, id: \.self) { group in
            let groupRules = rules.filter { $0.group == group }
            if !groupRules.isEmpty {
                IDESettingsSection(group.title) {
                    groupToggle(group, rules: groupRules)
                    ForEach(groupRules, id: \.self) { rule in
                        row(for: rule)
                    }
                }
            }
        }

        if rules.isEmpty {
            Text(query.isEmpty ? "No inspection matches this filter." : "No inspection matches \u{201C}\(query)\u{201D}.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
    }

    // MARK: Profile bar

    private var profileBar: some View {
        HStack(spacing: IDEAppearance.Spacing.md) {
            Picker("Profile", selection: sourceBinding) {
                if inspections.hasProjectProfile {
                    Text("Project (shared)").tag(IDEWorkspaceInspections.Source.project)
                    Divider()
                }
                ForEach(store.names, id: \.self) { name in
                    Text(name).tag(IDEWorkspaceInspections.Source.global(name))
                }
            }
            .frame(maxWidth: 280)
            Menu("Profile Actions") {
                Button("Duplicate…") { ask(.duplicate, initial: profile.name + " Copy") }
                if case .global(let name) = inspections.activeSource, name != IDEInspectionProfiles.defaultName {
                    Button("Rename…") { ask(.rename, initial: name) }
                    Button("Delete", role: .destructive) {
                        store.delete(name)
                        inspections.select(.global(store.selectedName))
                    }
                }
                Button("New Empty Profile…") { ask(.new, initial: "My Profile") }
                Divider()
                Button("Restore Defaults") { edit { $0 = JavaInspectionProfile.standard(name: $0.name) } }
                Button("Reset to Empty (all inspections off)") { edit { $0 = JavaInspectionProfile.empty(name: $0.name) } }
                Divider()
                if inspections.root != nil {
                    if inspections.hasProjectProfile {
                        Button("Save Project Profile as Global…") { ask(.copyToGlobal, initial: "Project Profile") }
                        Button("Remove Project Profile", role: .destructive) { inspections.removeProjectProfile() }
                    } else {
                        Button("Use a Copy in This Project") { inspections.copyToProject() }
                    }
                    Divider()
                }
                Button("Export…") { exportProfile() }
                Button("Import…") { importProfile() }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func ask(_ kind: NamePrompt, initial: String) {
        promptText = initial
        prompt = kind
    }

    private func commitPrompt() {
        guard let kind = prompt else { return }
        prompt = nil
        let name = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        switch kind {
        case .duplicate:
            let created = store.create(named: name, from: profile)
            inspections.select(.global(created.name))
        case .new:
            let created = store.create(named: name, from: .empty(name: name))
            inspections.select(.global(created.name))
        case .rename:
            if case .global(let old) = inspections.activeSource {
                store.rename(old, to: name)
                inspections.select(.global(store.selectedName))
            }
        case .copyToGlobal:
            if let saved = inspections.copyToGlobal(named: name) { message = "Saved as \u{201C}\(saved)\u{201D}." }
        }
    }

    private func exportProfile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(profile.name).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try IDEInspectionProfiles.encoded(profile).write(to: url, options: .atomic)
            message = "Exported to \(url.lastPathComponent)."
        } catch {
            message = "Could not export: \(error.localizedDescription)"
        }
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url), let imported = try? JSONDecoder().decode(JavaInspectionProfile.self, from: data) else {
            message = "\(url.lastPathComponent) is not an inspection profile."
            return
        }
        let created = store.create(named: imported.name, from: imported)
        inspections.select(.global(created.name))
        message = "Imported as \u{201C}\(created.name)\u{201D}."
    }

    private var sourceBinding: Binding<IDEWorkspaceInspections.Source> {
        Binding {
            inspections.activeSource
        } set: { source in
            inspections.select(source)
        }
    }

    private func edit(_ change: (inout JavaInspectionProfile) -> Void) {
        inspections.edit(nil, change)
    }

    private func focusRequestedRule() {
        guard let code = inspections.focusedRuleCode else { return }
        query = code
        filter = .all
        expandedScopes.insert(code)
        inspections.focusedRuleCode = nil
    }

    // MARK: Groups and rules

    private func groupToggle(_ group: JavaInspectionGroup, rules: [JavaInspectionRule]) -> some View {
        let profile = profile
        let enabledCount = rules.filter { profile.isEnabled($0) }.count
        let symbol = enabledCount == rules.count ? "checkmark.square.fill" : (enabledCount == 0 ? "square" : "minus.square.fill")
        return Button {
            let turnOn = enabledCount != rules.count
            edit { profile in
                for rule in rules { profile.setEnabled(turnOn, for: rule) }
            }
        } label: {
            Label(enabledCount == rules.count ? "Turn off all in \(group.title)" : "Turn on all in \(group.title)", systemImage: symbol)
                .font(IDEAppearance.Typography.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(IDEAppearance.ColorToken.muted)
    }

    private func row(for rule: JavaInspectionRule) -> some View {
        let profile = profile
        let resolution = profile.resolution(of: rule)
        let overrides = profile.scopedOverrides.filter { $0.code == rule.code }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: IDEAppearance.Spacing.md) {
                Toggle(rule.title, isOn: enabledBinding(rule))
                    .toggleStyle(.checkbox)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                if rule.hasQuickFix {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .help("Has a quick fix")
                }
                Spacer(minLength: IDEAppearance.Spacing.md)
                Picker("Severity", selection: severityBinding(rule)) {
                    ForEach(JavaInspection.Severity.allCases, id: \.self) { severity in
                        Text(severity.settingsTitle).tag(severity)
                    }
                }
                .labelsHidden()
                .frame(width: 210)
                .disabled(!resolution.isEnabled)
                .accessibilityLabel("Severity of \(rule.title)")
            }
            Text(rule.summary)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 20)
            if let limit = rule.limit {
                Stepper(value: limitBinding(rule), in: limit.range, step: limit.step) {
                    Text("\(limit.label): \(profile.thresholds.value(for: rule))")
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.foreground)
                }
                .disabled(!resolution.isEnabled)
                .padding(.leading, 20)
            }
            scopes(for: rule, overrides: overrides)
        }
    }

    private func scopes(for rule: JavaInspectionRule, overrides: [JavaInspectionProfile.ScopedOverride]) -> some View {
        let isOpen = expandedScopes.contains(rule.code)
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                if isOpen { expandedScopes.remove(rule.code) } else { expandedScopes.insert(rule.code) }
            } label: {
                Label(
                    overrides.isEmpty ? "Scopes" : "Scopes (\(overrides.count))",
                    systemImage: isOpen ? "chevron.down" : "chevron.right"
                )
                .font(IDEAppearance.Typography.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
            .padding(.leading, 20)
            if isOpen {
                ForEach(overrides, id: \.self) { override in
                    scopeRow(override)
                }
                Menu("Add Scope") {
                    Button("Tests") { addScope(.tests, for: rule) }
                    Button("Files Matching…") { addScope(.glob("**/generated/**"), for: rule) }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.leading, 36)
                Text("Everywhere else uses the choices above. The first matching scope wins.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .padding(.leading, 36)
            }
        }
    }

    private func scopeRow(_ override: JavaInspectionProfile.ScopedOverride) -> some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            switch override.scope {
            case .tests:
                Text("Tests").frame(width: 150, alignment: .leading)
            case .glob(let pattern):
                TextField("Path pattern", text: Binding(
                    get: { pattern },
                    set: { value in replace(override) { $0.scope = .glob(value) } }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
            }
            Picker("State", selection: Binding(
                get: { override.isEnabled.map { $0 ? 1 : 0 } ?? 2 },
                set: { value in replace(override) { $0.isEnabled = value == 2 ? nil : value == 1 } }
            )) {
                Text("Inherit").tag(2)
                Text("On").tag(1)
                Text("Off").tag(0)
            }
            .labelsHidden()
            .frame(width: 90)
            Picker("Severity", selection: Binding(
                get: { override.severity ?? "" },
                set: { value in replace(override) { $0.severity = value.isEmpty ? nil : value } }
            )) {
                Text("Inherit").tag("")
                ForEach(JavaInspection.Severity.allCases, id: \.self) { severity in
                    Text(severity.settingsTitle).tag(severity.rawValue)
                }
            }
            .labelsHidden()
            .frame(width: 210)
            Button { move(override, by: -1) } label: { Image(systemName: "arrow.up") }
                .buttonStyle(.borderless)
                .help("Check this scope earlier")
            Button { move(override, by: 1) } label: { Image(systemName: "arrow.down") }
                .buttonStyle(.borderless)
                .help("Check this scope later")
            Button { edit { $0.scopedOverrides.removeAll { $0 == override } } } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("Remove this scope")
        }
        .padding(.leading, 36)
    }

    private func addScope(_ scope: JavaInspectionProfile.Scope, for rule: JavaInspectionRule) {
        edit { $0.scopedOverrides.append(.init(code: rule.code, scope: scope, isEnabled: false)) }
        expandedScopes.insert(rule.code)
    }

    private func replace(_ old: JavaInspectionProfile.ScopedOverride, _ change: (inout JavaInspectionProfile.ScopedOverride) -> Void) {
        edit { profile in
            guard let index = profile.scopedOverrides.firstIndex(of: old) else { return }
            change(&profile.scopedOverrides[index])
        }
    }

    private func move(_ override: JavaInspectionProfile.ScopedOverride, by delta: Int) {
        edit { profile in
            guard let index = profile.scopedOverrides.firstIndex(of: override) else { return }
            let sameRule = profile.scopedOverrides.indices.filter { profile.scopedOverrides[$0].code == override.code }
            guard let position = sameRule.firstIndex(of: index), sameRule.indices.contains(position + delta) else { return }
            profile.scopedOverrides.swapAt(index, sameRule[position + delta])
        }
    }

    // MARK: Bindings

    private func enabledBinding(_ rule: JavaInspectionRule) -> Binding<Bool> {
        Binding {
            profile.isEnabled(rule)
        } set: { isOn in
            edit { $0.setEnabled(isOn, for: rule) }
        }
    }

    private var publicApiBinding: Binding<Bool> {
        Binding {
            profile.treatsPublicApiAsUsed
        } set: { value in
            edit { $0.treatsPublicApiAsUsed = value }
        }
    }

    private func limitBinding(_ rule: JavaInspectionRule) -> Binding<Int> {
        Binding {
            profile.thresholds.value(for: rule)
        } set: { value in
            edit { $0.setLimit(value, for: rule) }
        }
    }

    private func severityBinding(_ rule: JavaInspectionRule) -> Binding<JavaInspection.Severity> {
        Binding {
            profile.resolution(of: rule).severity
        } set: { severity in
            edit { $0.setSeverity(severity, for: rule) }
        }
    }
}

private extension JavaInspection.Severity {
    var settingsTitle: String {
        switch self {
        case .error: "Error"
        case .warning: "Warning"
        case .weakWarning: "Weak Warning"
        case .info: "Consideration"
        case .noHighlighting: "No highlighting (fix available)"
        }
    }
}
