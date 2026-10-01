import JavaIntelligence
import SwiftUI

/// Settings › Inspections: every Java inspection by group, with an on/off checkbox and a severity.
/// Only deviations from a rule's default are stored (`IDEPreferences.javaInspectionSeverities`).
struct IDEPreferencesInspectionsPane: View {
    @Bindable var preferences: IDEPreferences
    @Environment(IDEWorkspace.self) private var workspace
    @State private var query = ""

    private var matchingRules: [JavaInspectionRule] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return JavaInspectionRule.allCases }
        return JavaInspectionRule.allCases.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.summary.localizedCaseInsensitiveContains(query)
                || $0.code.localizedCaseInsensitiveContains(query)
                || $0.group.title.localizedCaseInsensitiveContains(query)
        }
    }

    private var hasChanges: Bool {
        !preferences.javaDisabledInspections.isEmpty || !preferences.javaInspectionSeverities.isEmpty
    }

    var body: some View {
        IDESettingsSection(
            "Java Inspections",
            footer: "Warnings appear under Problems and in the error stripe. Silence one place with a quick fix (Suppress for method or class), or a comment: //noinspection <id>."
        ) {
            HStack(spacing: IDEAppearance.Spacing.md) {
                TextField("Filter inspections", text: $query)
                    .textFieldStyle(.roundedBorder)
                Button("Restore Defaults") {
                    preferences.resetJavaInspections()
                    workspace.javaInspectionPreferencesChanged()
                }
                .disabled(!hasChanges)
            }
        }

        let rules = matchingRules
        ForEach(JavaInspectionGroup.allCases, id: \.self) { group in
            let groupRules = rules.filter { $0.group == group }
            if !groupRules.isEmpty {
                IDESettingsSection(group.title) {
                    ForEach(groupRules, id: \.self) { rule in
                        row(for: rule)
                    }
                }
            }
        }

        if rules.isEmpty {
            Text("No inspection matches \u{201C}\(query)\u{201D}.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
    }

    private func row(for rule: JavaInspectionRule) -> some View {
        let isEnabled = preferences.isEnabled(rule)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: IDEAppearance.Spacing.md) {
                Toggle(rule.title, isOn: enabledBinding(rule))
                    .toggleStyle(.checkbox)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                Spacer(minLength: IDEAppearance.Spacing.md)
                Picker("Severity", selection: severityBinding(rule)) {
                    ForEach(JavaInspection.Severity.allCases, id: \.self) { severity in
                        Text(severity.settingsTitle).tag(severity)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
                .disabled(!isEnabled)
                .accessibilityLabel("Severity of \(rule.title)")
            }
            Text(rule.summary)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 20)
        }
    }

    private func enabledBinding(_ rule: JavaInspectionRule) -> Binding<Bool> {
        Binding {
            preferences.isEnabled(rule)
        } set: { isOn in
            preferences.setEnabled(isOn, for: rule)
            workspace.javaInspectionPreferencesChanged()
        }
    }

    private func severityBinding(_ rule: JavaInspectionRule) -> Binding<JavaInspection.Severity> {
        Binding {
            preferences.severity(of: rule)
        } set: { severity in
            preferences.setSeverity(severity, for: rule)
            workspace.javaInspectionPreferencesChanged()
        }
    }
}

private extension JavaInspection.Severity {
    var settingsTitle: String {
        switch self {
        case .error: "Error"
        case .warning: "Warning"
        case .weakWarning: "Weak Warning"
        case .info: "Info"
        }
    }
}
