import EditorIntelligence
import Foundation
import JavaIntelligence
import SwiftIntelligence

/// The languages Inspect Code runs over. A run covers one: its files, rules and fixes are that language's.
enum IDEInspectionLanguage: String, Hashable, Sendable {
    case java
    case swift

    var title: String {
        switch self {
        case .java: "Java"
        case .swift: "Swift"
        }
    }

    /// The extension of the files a run covers.
    var fileExtension: String { rawValue }

    /// The Settings page that holds the language's inspections.
    var settingsDomain: IDEPreferencesDomain {
        switch self {
        case .java: .java
        case .swift: .swift
        }
    }
}

/// Severity as the results list shows it: Java's five levels, of which Swift uses four.
enum IDEInspectionSeverity: String, Hashable, Sendable, CaseIterable {
    case error
    case warning
    case weakWarning
    case info
    case noHighlighting

    init(_ severity: JavaInspection.Severity) {
        switch severity {
        case .error: self = .error
        case .warning: self = .warning
        case .weakWarning: self = .weakWarning
        case .info: self = .info
        case .noHighlighting: self = .noHighlighting
        }
    }

    init(_ severity: SwiftInspection.Severity) {
        switch severity {
        case .error: self = .error
        case .warning: self = .warning
        case .weakWarning: self = .weakWarning
        case .info: self = .info
        case .noHighlighting: self = .noHighlighting
        }
    }

    /// Java's level, for a report format that is typed on it.
    var java: JavaInspection.Severity {
        switch self {
        case .error: .error
        case .warning: .warning
        case .weakWarning: .weakWarning
        case .info: .info
        case .noHighlighting: .noHighlighting
        }
    }
}

/// One finding of an Inspect Code run, whichever language made it. It keeps the language's own value, which
/// the fixes and the report formats still need, behind the fields the list and the tree read.
struct IDEInspectionFinding: Hashable, Sendable {
    enum Origin: Hashable, Sendable {
        case java(JavaInspection)
        case swift(SwiftLocatedInspection)
    }

    let origin: Origin

    init(_ inspection: JavaInspection) { origin = .java(inspection) }
    init(_ inspection: SwiftLocatedInspection) { origin = .swift(inspection) }

    var language: IDEInspectionLanguage {
        switch origin {
        case .java: .java
        case .swift: .swift
        }
    }

    /// The rule's code.
    var id: String {
        switch origin {
        case .java(let inspection): inspection.id
        case .swift(let located): located.inspection.id
        }
    }

    var message: String {
        switch origin {
        case .java(let inspection): inspection.message
        case .swift(let located): located.inspection.message
        }
    }

    var severity: IDEInspectionSeverity {
        switch origin {
        case .java(let inspection): IDEInspectionSeverity(inspection.severity)
        case .swift(let located): IDEInspectionSeverity(located.inspection.severity)
        }
    }

    var range: EditorIntelligence.TextRange {
        switch origin {
        case .java(let inspection): inspection.range
        case .swift(let located): located.range
        }
    }

    func asDiagnostic() -> Diagnostic {
        switch origin {
        case .java(let inspection): inspection.asDiagnostic()
        case .swift(let located): located.asDiagnostic()
        }
    }
}

/// What the results list and the Inspect Code sheets show about a rule, whichever language owns it.
struct IDEInspectionRuleInfo: Hashable, Identifiable {
    let language: IDEInspectionLanguage
    let code: String
    let title: String
    let summary: String
    let groupTitle: String
    let hasQuickFix: Bool

    var id: String { "\(language.rawValue):\(code)" }

    init(_ rule: JavaInspectionRule) {
        language = .java
        code = rule.code
        title = rule.title
        summary = rule.summary
        groupTitle = rule.group.title
        hasQuickFix = rule.hasQuickFix
    }

    init(_ rule: SwiftInspectionRule) {
        language = .swift
        code = rule.code
        title = rule.title
        summary = rule.summary
        groupTitle = rule.group.title
        hasQuickFix = rule.hasFixes
    }
}

extension IDEInspectionLanguage {
    func rule(code: String) -> IDEInspectionRuleInfo? {
        switch self {
        case .java: JavaInspectionRule(code: code).map(IDEInspectionRuleInfo.init)
        case .swift: SwiftInspectionRule(code: code).map(IDEInspectionRuleInfo.init)
        }
    }

    /// Every rule, for Run Inspection by Name.
    var rules: [IDEInspectionRuleInfo] {
        switch self {
        case .java: JavaInspectionRule.allCases.map(IDEInspectionRuleInfo.init)
        case .swift: SwiftInspectionRule.allCases.map(IDEInspectionRuleInfo.init)
        }
    }
}
