import Foundation

/// Where a file sits in a project, as far as scoped inspection settings care.
public struct SwiftInspectionFileContext: Sendable, Equatable {
    /// Path relative to the project root, with `/` separators (the file name alone outside one).
    public let relativePath: String
    public let isTest: Bool

    public init(relativePath: String, isTest: Bool) {
        self.relativePath = relativePath
        self.isTest = isTest
    }
}

/// Tells which files are tests and gives each a project-relative path.
public struct SwiftInspectionFileClassifier: Sendable, Equatable {
    public var projectRoot: URL?

    public init(projectRoot: URL? = nil) {
        self.projectRoot = projectRoot?.standardizedFileURL
    }

    public func context(for url: URL) -> SwiftInspectionFileContext {
        let standardized = url.standardizedFileURL
        var relative = standardized.lastPathComponent
        if let root = projectRoot?.path, standardized.path.hasPrefix(root + "/") {
            relative = String(standardized.path.dropFirst(root.count + 1))
        }
        return SwiftInspectionFileContext(relativePath: relative, isTest: SwiftInspectionScope.isTest(standardized))
    }
}

extension SwiftInspectionRule {
    /// A metric rule's threshold: its default, the range Settings offers and the stepper's step.
    public struct Limit: Sendable, Equatable {
        public let defaultValue: Int
        public let range: ClosedRange<Int>
        public let step: Int
        public let unit: String
    }

    public var limit: Limit? {
        switch self {
        case .longFunction: Limit(defaultValue: SwiftInspectionLimits.standard.functionLines, range: 10 ... 1_000, step: 10, unit: "lines")
        case .highComplexity: Limit(defaultValue: SwiftInspectionLimits.standard.complexity, range: 2 ... 100, step: 1, unit: "decision points")
        case .manyParameters: Limit(defaultValue: SwiftInspectionLimits.standard.parameters, range: 2 ... 30, step: 1, unit: "parameters")
        default: nil
        }
    }
}

/// A named set of Swift inspection choices: which rules are on, their severities and thresholds, and per-scope
/// exceptions (tests, a folder). Like Java's, it stores rules by code and only the deviations from each rule's
/// default, so a rule that is later switched on by default is picked up and a code this build does not know
/// survives a round trip.
///
/// It lives inside the same profile file as Java's (the `swift` section of an Umbra inspection profile).
public struct SwiftInspectionProfile: Sendable, Equatable, Codable {
    /// Where an override applies.
    public enum Scope: Sendable, Equatable, Hashable, Codable {
        /// Files under a `Tests` folder or named `*Tests.swift`.
        case tests
        /// Files whose project-relative path matches the glob (`**/Generated/**`, `*+Mocks.swift`).
        case glob(String)

        public init(from decoder: Decoder) throws {
            let text = try decoder.singleValueContainer().decode(String.self)
            if text == "tests" {
                self = .tests
            } else if text.hasPrefix("glob:") {
                self = .glob(String(text.dropFirst(5)))
            } else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Unknown inspection scope '\(text)'")
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .tests: try container.encode("tests")
            case .glob(let pattern): try container.encode("glob:\(pattern)")
            }
        }

        public func matches(_ file: SwiftInspectionFileContext) -> Bool {
            switch self {
            case .tests: file.isTest
            case .glob(let pattern): SwiftPathGlob.matches(pattern: pattern, path: file.relativePath)
            }
        }

        public var title: String {
            switch self {
            case .tests: "Tests"
            case .glob(let pattern): pattern
            }
        }
    }

    /// One exception to the profile's base choice. The first entry for a rule that matches a file wins.
    public struct ScopedOverride: Sendable, Equatable, Hashable, Codable {
        public var code: String
        public var scope: Scope
        /// `nil` keeps the base choice.
        public var isEnabled: Bool?
        /// A ``SwiftInspection/Severity`` raw value; `nil` keeps the base severity.
        public var severity: String?

        public init(code: String, scope: Scope, isEnabled: Bool? = nil, severity: String? = nil) {
            self.code = code
            self.scope = scope
            self.isEnabled = isEnabled
            self.severity = severity
        }
    }

    /// What a rule comes to for one file.
    public struct Resolution: Sendable, Equatable {
        public let isEnabled: Bool
        public let severity: SwiftInspection.Severity
        /// The profile (or a scope) set the severity, as opposed to the rule's default.
        public let isSeverityExplicit: Bool
    }

    /// Rules that are on by default and switched off.
    public var disabled: Set<String>
    /// Rules that are off by default and switched on.
    public var enabled: Set<String>
    /// Severity raw value per rule code, only where it differs from the rule's default.
    public var severities: [String: String]
    /// Threshold per metric rule code, only where it differs from the default.
    public var limits: [String: Int]
    /// Whether the project-wide rules leave `public` and `open` declarations alone.
    public var treatsPublicApiAsUsed: Bool
    public var scopedOverrides: [ScopedOverride]

    public init(
        disabled: Set<String> = [], enabled: Set<String> = [], severities: [String: String] = [:],
        limits: [String: Int] = [:], treatsPublicApiAsUsed: Bool = true, scopedOverrides: [ScopedOverride] = []
    ) {
        self.disabled = disabled
        self.enabled = enabled
        self.severities = severities
        self.limits = limits
        self.treatsPublicApiAsUsed = treatsPublicApiAsUsed
        self.scopedOverrides = scopedOverrides
    }

    /// The rules' own defaults.
    public static let standard = SwiftInspectionProfile()

    /// Every rule off, to build a profile from only the rules you pick.
    public static var empty: SwiftInspectionProfile {
        SwiftInspectionProfile(disabled: Set(SwiftInspectionRule.allCases.filter(\.isEnabledByDefault).map(\.code)))
    }

    /// A profile that makes the same choices as `options`.
    public init(options: SwiftInspectionOptions) {
        self.init(
            disabled: options.disabled, enabled: options.enabled,
            severities: options.severities.mapValues(\.rawValue),
            limits: Self.limits(from: options.limits)
        )
    }

    private static func limits(from limits: SwiftInspectionLimits) -> [String: Int] {
        var result: [String: Int] = [:]
        let standard = SwiftInspectionLimits.standard
        if limits.functionLines != standard.functionLines { result[SwiftInspectionRule.longFunction.code] = limits.functionLines }
        if limits.complexity != standard.complexity { result[SwiftInspectionRule.highComplexity.code] = limits.complexity }
        if limits.parameters != standard.parameters { result[SwiftInspectionRule.manyParameters.code] = limits.parameters }
        return result
    }

    // MARK: Resolving

    public func resolution(of rule: SwiftInspectionRule, in file: SwiftInspectionFileContext? = nil) -> Resolution {
        var isEnabled = rule.isEnabledByDefault ? !disabled.contains(rule.code) : enabled.contains(rule.code)
        var severityRaw = severities[rule.code]
        if let file {
            for override in scopedOverrides where override.code == rule.code && override.scope.matches(file) {
                if let value = override.isEnabled { isEnabled = value }
                if let value = override.severity { severityRaw = value }
                break
            }
        }
        let parsed = severityRaw.flatMap(SwiftInspection.Severity.init(rawValue:))
        return Resolution(isEnabled: isEnabled, severity: parsed ?? rule.defaultSeverity, isSeverityExplicit: parsed != nil)
    }

    public func isEnabled(_ rule: SwiftInspectionRule, in file: SwiftInspectionFileContext? = nil) -> Bool {
        resolution(of: rule, in: file).isEnabled
    }

    /// The thresholds the metric rules use.
    public var inspectionLimits: SwiftInspectionLimits {
        let standard = SwiftInspectionLimits.standard
        return SwiftInspectionLimits(
            functionLines: limits[SwiftInspectionRule.longFunction.code] ?? standard.functionLines,
            complexity: limits[SwiftInspectionRule.highComplexity.code] ?? standard.complexity,
            parameters: limits[SwiftInspectionRule.manyParameters.code] ?? standard.parameters
        )
    }

    /// The options the pipeline runs with for `file` (the base choices when no file is given): the profile's, with
    /// the first scope that matches the file applied to each rule.
    public func options(for file: SwiftInspectionFileContext? = nil) -> SwiftInspectionOptions {
        var options = SwiftInspectionOptions(
            disabled: disabled, enabled: enabled,
            severities: severities.compactMapValues(SwiftInspection.Severity.init(rawValue:)), limits: inspectionLimits
        )
        guard let file, !scopedOverrides.isEmpty else { return options }
        for rule in SwiftInspectionRule.allCases {
            let resolved = resolution(of: rule, in: file)
            if rule.isEnabledByDefault {
                if resolved.isEnabled { options.disabled.remove(rule.code) } else { options.disabled.insert(rule.code) }
            } else {
                if resolved.isEnabled { options.enabled.insert(rule.code) } else { options.enabled.remove(rule.code) }
            }
            if resolved.isSeverityExplicit { options.severities[rule.code] = resolved.severity } else { options.severities[rule.code] = nil }
        }
        return options
    }

    // MARK: Editing

    public mutating func setEnabled(_ isEnabled: Bool, for rule: SwiftInspectionRule) {
        if isEnabled == rule.isEnabledByDefault {
            disabled.remove(rule.code)
            enabled.remove(rule.code)
        } else if isEnabled {
            enabled.insert(rule.code)
        } else {
            disabled.insert(rule.code)
        }
    }

    /// Storing the rule's default severity removes the entry, so the profile only holds deviations.
    public mutating func setSeverity(_ severity: SwiftInspection.Severity, for rule: SwiftInspectionRule) {
        severities[rule.code] = severity == rule.defaultSeverity ? nil : severity.rawValue
    }

    public mutating func setLimit(_ value: Int, for rule: SwiftInspectionRule) {
        guard let limit = rule.limit else { return }
        let clamped = min(max(value, limit.range.lowerBound), limit.range.upperBound)
        limits[rule.code] = clamped == limit.defaultValue ? nil : clamped
    }

    /// Whether the profile differs from the rule defaults for `rule`.
    public func isModified(_ rule: SwiftInspectionRule) -> Bool {
        disabled.contains(rule.code) || enabled.contains(rule.code) || severities[rule.code] != nil
            || limits[rule.code] != nil || scopedOverrides.contains { $0.code == rule.code }
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case disabled, enabled, severities, limits, treatsPublicApiAsUsed, scopedOverrides
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        disabled = Set(try container.decodeIfPresent([String].self, forKey: .disabled) ?? [])
        enabled = Set(try container.decodeIfPresent([String].self, forKey: .enabled) ?? [])
        severities = try container.decodeIfPresent([String: String].self, forKey: .severities) ?? [:]
        limits = try container.decodeIfPresent([String: Int].self, forKey: .limits) ?? [:]
        treatsPublicApiAsUsed = try container.decodeIfPresent(Bool.self, forKey: .treatsPublicApiAsUsed) ?? true
        scopedOverrides = try container.decodeIfPresent([ScopedOverride].self, forKey: .scopedOverrides) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(disabled.sorted(), forKey: .disabled)
        try container.encode(enabled.sorted(), forKey: .enabled)
        try container.encode(severities, forKey: .severities)
        try container.encode(limits, forKey: .limits)
        try container.encode(treatsPublicApiAsUsed, forKey: .treatsPublicApiAsUsed)
        try container.encode(scopedOverrides, forKey: .scopedOverrides)
    }

    // MARK: Section data

    /// The JSON a profile file keeps this profile as: sorted keys, so an unchanged profile is byte-identical.
    public var sectionData: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data()
    }

    public init?(sectionData: Data?) {
        guard let sectionData, let decoded = try? JSONDecoder().decode(SwiftInspectionProfile.self, from: sectionData) else { return nil }
        self = decoded
    }
}
