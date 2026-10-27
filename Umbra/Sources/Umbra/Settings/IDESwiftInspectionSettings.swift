import Foundation
import Observation
import SwiftIntelligence
import SwiftUI

/// The user's choices for the native Swift inspections, kept as deviations from each rule's default, so a
/// rule that is later switched on by default is picked up and a renamed case cannot lose a choice (the
/// values are rule codes). Machine-local, like Java's inspection profile: not part of the shared snapshot.
enum IDESwiftInspectionSettings {
    static let disabledKey = "com.umbra.editor.swiftDisabledInspections"
    static let enabledKey = "com.umbra.editor.swiftEnabledInspections"
    static let severitiesKey = "com.umbra.editor.swiftInspectionSeverities"
    static let limitsKey = "com.umbra.editor.swiftInspectionLimits"

    /// Read at analysis time, from whichever thread the diagnostic provider runs on, so a change in
    /// Settings reaches the next pass without any plumbing.
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

    static func save(_ options: SwiftInspectionOptions, defaults: UserDefaults = .standard) {
        defaults.set(options.disabled.sorted(), forKey: disabledKey)
        defaults.set(options.enabled.sorted(), forKey: enabledKey)
        defaults.set(options.severities.mapValues(\.rawValue), forKey: severitiesKey)
        let standard = SwiftInspectionLimits.standard
        var limits: [String: Int] = [:]
        if options.limits.functionLines != standard.functionLines { limits[SwiftInspectionRule.longFunction.code] = options.limits.functionLines }
        if options.limits.complexity != standard.complexity { limits[SwiftInspectionRule.highComplexity.code] = options.limits.complexity }
        if options.limits.parameters != standard.parameters { limits[SwiftInspectionRule.manyParameters.code] = options.limits.parameters }
        defaults.set(limits, forKey: limitsKey)
    }

    /// The default value of a rule's limit and the steps the stepper offers.
    static func limit(of rule: SwiftInspectionRule, in options: SwiftInspectionOptions) -> (value: Int, range: ClosedRange<Int>, step: Int, unit: String)? {
        switch rule {
        case .longFunction: (options.limits.functionLines, 10 ... 1_000, 10, "lines")
        case .highComplexity: (options.limits.complexity, 2 ... 100, 1, "decision points")
        case .manyParameters: (options.limits.parameters, 2 ... 30, 1, "parameters")
        default: nil
        }
    }
}

/// What the Swift pane edits. Saves on every change and tells the open editors to run their inspections again.
@MainActor
@Observable
final class IDESwiftInspectionModel {
    var options: SwiftInspectionOptions

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        options = IDESwiftInspectionSettings.current(defaults: defaults)
    }

    func isEnabled(_ rule: SwiftInspectionRule) -> Bool { options.isEnabled(rule) }

    func setEnabled(_ enabled: Bool, for rule: SwiftInspectionRule) {
        if enabled == rule.isEnabledByDefault {
            options.disabled.remove(rule.code)
            options.enabled.remove(rule.code)
        } else if enabled {
            options.enabled.insert(rule.code)
        } else {
            options.disabled.insert(rule.code)
        }
        commit()
    }

    func severity(of rule: SwiftInspectionRule) -> SwiftInspection.Severity { options.severity(of: rule) }

    func setSeverity(_ severity: SwiftInspection.Severity, for rule: SwiftInspectionRule) {
        options.severities[rule.code] = severity == rule.defaultSeverity ? nil : severity
        commit()
    }

    func setLimit(_ value: Int, for rule: SwiftInspectionRule) {
        switch rule {
        case .longFunction: options.limits.functionLines = value
        case .highComplexity: options.limits.complexity = value
        case .manyParameters: options.limits.parameters = value
        default: return
        }
        commit()
    }

    func resetToDefaults() {
        options = SwiftInspectionOptions()
        commit()
    }

    private func commit() {
        IDESwiftInspectionSettings.save(options, defaults: defaults)
        IDEWindowRegistry.shared.swiftInspectionPreferencesChangedInAllWindows()
    }
}

extension SwiftInspection.Severity {
    var title: String {
        switch self {
        case .error: "Error"
        case .warning: "Warning"
        case .weakWarning: "Weak warning"
        case .info: "Consideration"
        }
    }
}

/// Settings ▸ Swift ▸ Inspections: every rule, grouped, with an on/off switch, a severity and, for the metric
/// rules, the threshold.
struct IDESwiftInspectionsSettings: View {
    @State private var model = IDESwiftInspectionModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(SwiftInspectionGroup.allCases, id: \.self) { group in
                IDESettingsSection(group.title, footer: group == .probableBugs ? Self.footer : nil) {
                    ForEach(SwiftInspectionRule.allCases.filter { $0.group == group }, id: \.self) { rule in
                        ruleRows(rule)
                    }
                }
            }
            Button("Restore Defaults") { model.resetToDefaults() }
                .controlSize(.small)
        }
    }

    private static let footer =
        "Native checks that run as you type, for the things the compiler does not report. `// umbra:disable <rule>` above a statement turns a rule off inside it; SwiftLint's own disable comments work for the rules that have an equivalent."

    @ViewBuilder
    private func ruleRows(_ rule: SwiftInspectionRule) -> some View {
        IDESettingsToggle(
            rule.title,
            isOn: Binding(get: { model.isEnabled(rule) }, set: { model.setEnabled($0, for: rule) }),
            detail: rule.summary
        )
        if model.isEnabled(rule) {
            IDESettingsPicker(
                "Severity",
                selection: Binding(get: { model.severity(of: rule) }, set: { model.setSeverity($0, for: rule) })
            ) {
                ForEach(SwiftInspection.Severity.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if let limit = IDESwiftInspectionSettings.limit(of: rule, in: model.options) {
                IDESettingsRow("Limit") {
                    Stepper(
                        "\(limit.value) \(limit.unit)",
                        value: Binding(get: { limit.value }, set: { model.setLimit($0, for: rule) }),
                        in: limit.range, step: limit.step
                    )
                }
            }
        }
    }
}
