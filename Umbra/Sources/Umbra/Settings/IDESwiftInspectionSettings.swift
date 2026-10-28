import Foundation
import JavaIntelligence
import SwiftIntelligence
import SwiftUI

/// What Settings ▸ Swift kept before inspections had profiles: four flat keys. They are read once to seed the Default
/// profile's Swift section (`IDEInspectionProfiles`) and forgotten when that section is first written.
enum IDESwiftInspectionSettings {
    static let disabledKey = "com.umbra.editor.swiftDisabledInspections"
    static let enabledKey = "com.umbra.editor.swiftEnabledInspections"
    static let severitiesKey = "com.umbra.editor.swiftInspectionSeverities"
    static let limitsKey = "com.umbra.editor.swiftInspectionLimits"

    nonisolated static func current(defaults: UserDefaults = .standard) -> SwiftInspectionOptions {
        var options = SwiftInspectionOptions()
        options.disabled = Set(defaults.stringArray(forKey: disabledKey) ?? [])
        options.enabled = Set(defaults.stringArray(forKey: enabledKey) ?? [])
        let severities = defaults.dictionary(forKey: severitiesKey) as? [String: String] ?? [:]
        options.severities = severities.compactMapValues(SwiftInspection.Severity.init(rawValue:))
        let limits = defaults.dictionary(forKey: limitsKey) as? [String: Int] ?? [:]
        let standard = SwiftInspectionLimits.standard
        options.limits = SwiftInspectionLimits(
            functionLines: limits[SwiftInspectionRule.longFunction.code] ?? standard.functionLines,
            complexity: limits[SwiftInspectionRule.highComplexity.code] ?? standard.complexity,
            parameters: limits[SwiftInspectionRule.manyParameters.code] ?? standard.parameters
        )
        return options
    }

    /// Forgets the flat keys once the Default profile holds the Swift choices.
    static func clearLegacyKeys(defaults: UserDefaults = .standard) {
        for key in [disabledKey, enabledKey, severitiesKey, limitsKey] { defaults.removeObject(forKey: key) }
    }
}

extension SwiftInspection.Severity {
    var title: String {
        switch self {
        case .error: "Error"
        case .warning: "Warning"
        case .weakWarning: "Weak warning"
        case .info: "Consideration"
        case .noHighlighting: "No highlighting (fix available)"
        }
    }
}

/// Settings ▸ Swift ▸ Inspections: the active profile (the project's own, or a global one, the same list Java's pane
/// shows), every rule grouped, with an on/off switch, a severity, a threshold for the metric rules and per-scope
/// exceptions (tests, a path pattern). Only deviations from a rule's default are stored, in the profile's `swift`
/// section.
struct IDESwiftInspectionsSettings: View {
    @Environment(IDEWorkspace.self) private var workspace
    @State private var query = ""
    @State private var onlyModified = false
    @State private var selectedGroup: SwiftInspectionGroup = .probableBugs
    @State private var expanded: Set<String> = []
    @State private var prompt: NamePrompt?
    @State private var promptText = ""
    @State private var message: String?

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
    private var profile: SwiftInspectionProfile { inspections.activeSwiftProfile }

    private var matchingRules: [SwiftInspectionRule] {
        let text = query.trimmingCharacters(in: .whitespaces)
        let profile = profile
        return SwiftInspectionRule.allCases.filter { rule in
            if onlyModified, !profile.isModified(rule) { return false }
            guard !text.isEmpty else { return true }
            return rule.title.localizedCaseInsensitiveContains(text) || rule.summary.localizedCaseInsensitiveContains(text)
                || rule.code.localizedCaseInsensitiveContains(text) || rule.group.title.localizedCaseInsensitiveContains(text)
        }
    }

    var body: some View {
        IDESettingsSection(
            "Inspections",
            footer: "Native checks that run as you type, for the things the compiler does not report. A project can carry its own profile in .umbra/inspections.json, shared through version control (Java and Swift share the file). `// umbra:disable <rule>` above a statement turns a rule off inside it; SwiftLint's own disable comments work for the rules that have an equivalent."
        ) {
            profileBar
            HStack(spacing: IDEAppearance.Spacing.md) {
                TextField("Filter inspections", text: $query)
                    .textFieldStyle(.roundedBorder)
                Toggle("Modified", isOn: $onlyModified)
                    .toggleStyle(.checkbox)
            }
            if let message {
                Text(message)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            rules
        }
        .onAppear {
            store.reload()
            focusRequestedRule()
            ensureVisibleSelection()
        }
        .onChange(of: inspections.focusedRuleCode) { _, _ in focusRequestedRule() }
        .onChange(of: query) { _, _ in ensureVisibleSelection() }
        .onChange(of: onlyModified) { _, _ in ensureVisibleSelection() }
        .alert(prompt?.title ?? "", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })) {
            TextField("Name", text: $promptText)
            Button("OK") { commitPrompt() }
            Button("Cancel", role: .cancel) { prompt = nil }
        }
    }

    // MARK: Rules

    private var rules: some View {
        let matching = matchingRules
        let current = profile
        let groups = SwiftInspectionGroup.allCases.filter { group in matching.contains { $0.group == group } }
        return Group {
            if groups.isEmpty {
                Text(query.isEmpty ? "No inspection matches this filter." : "No inspection matches \u{201C}\(query)\u{201D}.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            } else {
                Picker("Group", selection: $selectedGroup) {
                    ForEach(groups, id: \.self) { group in
                        let members = matching.filter { $0.group == group }
                        Text("\(group.title) (\(members.filter { current.isEnabled($0) }.count)/\(members.count))").tag(group)
                    }
                }
                let selected = matching.filter { $0.group == selectedGroup }
                LazyVStack(alignment: .leading, spacing: IDEAppearance.Spacing.md) {
                    groupToggle(selectedGroup, rules: selected, profile: current)
                    ForEach(selected, id: \.self) { rule in
                        IDESwiftInspectionRuleRow(rule: rule, profile: current, expanded: $expanded, edit: edit)
                    }
                }
            }
        }
    }

    private func ensureVisibleSelection() {
        let matching = matchingRules
        guard !matching.contains(where: { $0.group == selectedGroup }) else { return }
        if let first = SwiftInspectionGroup.allCases.first(where: { group in matching.contains { $0.group == group } }) {
            selectedGroup = first
        }
    }

    private func groupToggle(_ group: SwiftInspectionGroup, rules: [SwiftInspectionRule], profile: SwiftInspectionProfile) -> some View {
        let enabledCount = rules.filter { profile.isEnabled($0) }.count
        let symbol = enabledCount == rules.count ? "checkmark.square.fill" : (enabledCount == 0 ? "square" : "minus.square.fill")
        return Button {
            let turnOn = enabledCount != rules.count
            edit { profile in for rule in rules { profile.setEnabled(turnOn, for: rule) } }
        } label: {
            Label(enabledCount == rules.count ? "Turn off all in \(group.title)" : "Turn on all in \(group.title)", systemImage: symbol)
                .font(IDEAppearance.Typography.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(IDEAppearance.ColorToken.muted)
    }

    private func focusRequestedRule() {
        guard let code = inspections.focusedRuleCode, let rule = SwiftInspectionRule(code: code) else { return }
        query = code
        onlyModified = false
        selectedGroup = rule.group
        expanded.insert(code)
        inspections.focusedRuleCode = nil
    }

    private func edit(_ change: (inout SwiftInspectionProfile) -> Void) {
        inspections.edit(nil) { profile in
            var swift = profile.swift
            change(&swift)
            profile.swift = swift
        }
    }

    // MARK: Profile bar

    private var profileBar: some View {
        HStack(spacing: IDEAppearance.Spacing.md) {
            Picker("Profile", selection: Binding(get: { inspections.activeSource }, set: { inspections.select($0) })) {
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
                Button("Duplicate…") { ask(.duplicate, initial: inspections.activeProfile.name + " Copy") }
                if case .global(let name) = inspections.activeSource, name != IDEInspectionProfiles.defaultName {
                    Button("Rename…") { ask(.rename, initial: name) }
                    Button("Delete", role: .destructive) {
                        store.delete(name)
                        inspections.select(.global(store.selectedName))
                    }
                }
                Button("New Empty Profile…") { ask(.new, initial: "My Profile") }
                Divider()
                Button("Restore Swift Defaults") { edit { $0 = .standard } }
                Button("Reset Swift to Empty (all inspections off)") { edit { $0 = .empty } }
                Divider()
                if inspections.root != nil {
                    if inspections.hasProjectProfile {
                        Button("Save Project Profile as Global…") { ask(.copyToGlobal, initial: "Project Profile") }
                        Button("Remove Project Profile", role: .destructive) { inspections.removeProjectProfile() }
                    } else {
                        Button("Use a Copy in This Project") { inspections.copyToProject() }
                    }
                }
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
            let created = store.create(named: name, from: inspections.activeProfile)
            inspections.select(.global(created.name))
        case .new:
            var empty = JavaInspectionProfile.empty(name: name)
            empty.swift = .empty
            let created = store.create(named: name, from: empty)
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
}

/// One Swift rule: switch, severity, threshold and scopes.
private struct IDESwiftInspectionRuleRow: View {
    let rule: SwiftInspectionRule
    let profile: SwiftInspectionProfile
    @Binding var expanded: Set<String>
    let edit: ((inout SwiftInspectionProfile) -> Void) -> Void

    @State private var pattern = ""

    private var resolution: SwiftInspectionProfile.Resolution { profile.resolution(of: rule) }
    private var overrides: [SwiftInspectionProfile.ScopedOverride] { profile.scopedOverrides.filter { $0.code == rule.code } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { resolution.isEnabled }, set: { value in edit { $0.setEnabled(value, for: rule) } })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(rule.title).font(IDEAppearance.Typography.body)
                    Text(rule.summary)
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            if resolution.isEnabled {
                HStack(spacing: IDEAppearance.Spacing.md) {
                    Picker("Severity", selection: Binding(get: { resolution.severity }, set: { value in edit { $0.setSeverity(value, for: rule) } })) {
                        ForEach(SwiftInspection.Severity.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .frame(maxWidth: 300)
                    if let limit = rule.limit {
                        let value = profile.limits[rule.code] ?? limit.defaultValue
                        Stepper(
                            "\(value) \(limit.unit)",
                            value: Binding(get: { value }, set: { new in edit { $0.setLimit(new, for: rule) } }),
                            in: limit.range, step: limit.step
                        )
                    }
                    Button(expanded.contains(rule.code) ? "Hide Scopes" : (overrides.isEmpty ? "Scopes…" : "Scopes (\(overrides.count))")) {
                        if expanded.contains(rule.code) { expanded.remove(rule.code) } else { expanded.insert(rule.code) }
                    }
                    .buttonStyle(.link)
                }
                .padding(.leading, 20)
                if expanded.contains(rule.code) { scopes.padding(.leading, 20) }
            }
        }
    }

    private var scopes: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(profile.scopedOverrides.enumerated()).filter { $0.element.code == rule.code }, id: \.offset) { index, override in
                HStack(spacing: IDEAppearance.Spacing.md) {
                    Text(override.scope.title).font(IDEAppearance.Typography.monoSmall).frame(minWidth: 120, alignment: .leading)
                    Picker("State", selection: Binding(
                        get: { override.isEnabled.map { $0 ? 1 : 0 } ?? -1 },
                        set: { value in change(index) { $0.isEnabled = value < 0 ? nil : value == 1 } }
                    )) {
                        Text("Like the profile").tag(-1)
                        Text("On").tag(1)
                        Text("Off").tag(0)
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    Picker("Severity", selection: Binding(
                        get: { override.severity ?? "" },
                        set: { value in change(index) { $0.severity = value.isEmpty ? nil : value } }
                    )) {
                        Text("Like the profile").tag("")
                        ForEach(SwiftInspection.Severity.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    Button { edit { $0.scopedOverrides.remove(at: index) } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Remove this scope")
                }
            }
            HStack(spacing: IDEAppearance.Spacing.md) {
                Button("Add Tests Scope") { add(.tests) }
                    .disabled(overrides.contains { $0.scope == .tests })
                TextField("Path pattern (Sources/**/Generated/**)", text: $pattern)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .onSubmit(addPattern)
                Button("Add", action: addPattern)
                    .disabled(pattern.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func change(_ index: Int, _ update: @escaping (inout SwiftInspectionProfile.ScopedOverride) -> Void) {
        edit { profile in
            guard profile.scopedOverrides.indices.contains(index) else { return }
            update(&profile.scopedOverrides[index])
        }
    }

    private func add(_ scope: SwiftInspectionProfile.Scope) {
        // A new scope starts as "switch the rule off here": the common reason to add one.
        edit { $0.scopedOverrides.append(.init(code: rule.code, scope: scope, isEnabled: false)) }
    }

    private func addPattern() {
        let text = pattern.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        add(.glob(text))
        pattern = ""
    }
}
