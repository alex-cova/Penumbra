import Foundation

/// Where a file sits in a project, as far as scoped inspection settings care.
public struct JavaInspectionFileContext: Sendable, Equatable {
    /// Path relative to the project root, with `/` separators (the file name alone outside one).
    public let relativePath: String
    public let isTest: Bool

    public init(relativePath: String, isTest: Bool) {
        self.relativePath = relativePath
        self.isTest = isTest
    }
}

/// Tells which files are tests and gives each a project-relative path.
public struct JavaInspectionFileClassifier: Sendable, Equatable {
    public var projectRoot: URL?
    /// Directories whose files are test sources (Gradle test source sets).
    public var testRoots: [String]

    public init(projectRoot: URL? = nil, testRoots: [URL] = []) {
        self.projectRoot = projectRoot?.standardizedFileURL
        self.testRoots = testRoots.map { $0.standardizedFileURL.path }
    }

    public func context(for url: URL) -> JavaInspectionFileContext {
        let path = url.standardizedFileURL.path
        var relative = (path as NSString).lastPathComponent
        if let root = projectRoot?.path, path.hasPrefix(root + "/") {
            relative = String(path.dropFirst(root.count + 1))
        }
        let inTestRoot = testRoots.contains { path.hasPrefix($0 + "/") }
        let looksLikeTest = path.contains("/src/test/") || path.contains("/src/integrationTest/")
        return JavaInspectionFileContext(relativePath: relative, isTest: inTestRoot || looksLikeTest)
    }
}

/// A named set of inspection choices: which rules are on, their severities and thresholds, and
/// per-scope exceptions (tests, a folder). Rules are stored by code, never by enum case, so a
/// renamed rule cannot lose a choice and codes this build does not know survive a round trip.
public struct JavaInspectionProfile: Sendable, Equatable, Codable {
    public static let defaultName = "Default"

    /// Where an override applies.
    public enum Scope: Sendable, Equatable, Hashable, Codable {
        /// Files in a test source set.
        case tests
        /// Files whose project-relative path matches the glob (`**/generated/**`, `*Dto.java`).
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

        public func matches(_ file: JavaInspectionFileContext) -> Bool {
            switch self {
            case .tests: file.isTest
            case .glob(let pattern): JavaPathGlob.matches(pattern: pattern, path: file.relativePath)
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
        /// A `JavaInspection.Severity` raw value; `nil` keeps the base severity.
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
        public let severity: JavaInspection.Severity
        /// The profile (or a scope) set the severity, as opposed to the rule's default.
        public let isSeverityExplicit: Bool
    }

    public var name: String
    /// Codes of the rules that are off.
    public var disabled: Set<String>
    /// Severity raw value per rule code, only where it differs from the rule's default.
    public var severities: [String: String]
    /// Threshold per metric rule code, only where it differs from the default.
    public var limits: [String: Int]
    public var treatsPublicApiAsUsed: Bool
    public var scopedOverrides: [ScopedOverride]
    /// What other languages keep in the same profile file, by key (`swift`), as the JSON they wrote. Read and written
    /// back untouched, so a profile edited for Java carries Swift's choices along and the other way round.
    public var sections: [String: Data]

    public init(
        name: String,
        disabled: Set<String>,
        severities: [String: String] = [:],
        limits: [String: Int] = [:],
        treatsPublicApiAsUsed: Bool = true,
        scopedOverrides: [ScopedOverride] = [],
        sections: [String: Data] = [:]
    ) {
        self.name = name
        self.disabled = disabled
        self.severities = severities
        self.limits = limits
        self.treatsPublicApiAsUsed = treatsPublicApiAsUsed
        self.scopedOverrides = scopedOverrides
        self.sections = sections
    }

    /// The rules' own defaults.
    public static func standard(name: String = defaultName) -> JavaInspectionProfile {
        JavaInspectionProfile(name: name, disabled: defaultDisabledCodes)
    }

    /// Every rule off, to build a profile from only the rules you pick.
    public static func empty(name: String) -> JavaInspectionProfile {
        JavaInspectionProfile(name: name, disabled: Set(JavaInspectionRule.allCases.map(\.code)))
    }

    public static var defaultDisabledCodes: Set<String> {
        Set(JavaInspectionRule.allCases.filter { !$0.isEnabledByDefault }.map(\.code))
    }

    // MARK: Resolving

    public func resolution(of rule: JavaInspectionRule, in file: JavaInspectionFileContext? = nil) -> Resolution {
        var isEnabled = !disabled.contains(rule.code)
        var severityRaw = severities[rule.code]
        if let file {
            for override in scopedOverrides where override.code == rule.code && override.scope.matches(file) {
                if let value = override.isEnabled { isEnabled = value }
                if let value = override.severity { severityRaw = value }
                break
            }
        }
        let parsed = severityRaw.flatMap(JavaInspection.Severity.init(rawValue:))
        return Resolution(isEnabled: isEnabled, severity: parsed ?? rule.defaultSeverity, isSeverityExplicit: parsed != nil)
    }

    public func isEnabled(_ rule: JavaInspectionRule, in file: JavaInspectionFileContext? = nil) -> Bool {
        resolution(of: rule, in: file).isEnabled
    }

    /// The rules that run on `file` (all rules the profile switches on when no file is given).
    public func enabledRules(in file: JavaInspectionFileContext? = nil) -> Set<JavaInspectionRule> {
        guard file != nil, !scopedOverrides.isEmpty else {
            return Set(JavaInspectionRule.allCases.filter { !disabled.contains($0.code) })
        }
        return Set(JavaInspectionRule.allCases.filter { resolution(of: $0, in: file).isEnabled })
    }

    public var thresholds: JavaInspectionThresholds {
        var values: [JavaInspectionRule: Int] = [:]
        for rule in JavaInspectionRule.allCases where rule.limit != nil {
            if let value = limits[rule.code] { values[rule] = value }
        }
        return JavaInspectionThresholds(values)
    }

    public var projectOptions: JavaProjectInspectionOptions {
        JavaProjectInspectionOptions(treatsPublicApiAsUsed: treatsPublicApiAsUsed)
    }

    // MARK: Editing

    public mutating func setEnabled(_ isEnabled: Bool, for rule: JavaInspectionRule) {
        if isEnabled { disabled.remove(rule.code) } else { disabled.insert(rule.code) }
    }

    /// Storing the rule's default severity removes the entry, so the profile only holds deviations.
    public mutating func setSeverity(_ severity: JavaInspection.Severity, for rule: JavaInspectionRule) {
        severities[rule.code] = severity == rule.defaultSeverity ? nil : severity.rawValue
    }

    public mutating func setLimit(_ value: Int, for rule: JavaInspectionRule) {
        guard let limit = rule.limit else { return }
        let clamped = min(max(value, limit.range.lowerBound), limit.range.upperBound)
        limits[rule.code] = clamped == limit.defaultValue ? nil : clamped
    }

    /// Whether the profile differs from the rule defaults for `rule`.
    public func isModified(_ rule: JavaInspectionRule) -> Bool {
        disabled.contains(rule.code) == rule.isEnabledByDefault
            || severities[rule.code] != nil
            || limits[rule.code] != nil
            || scopedOverrides.contains { $0.code == rule.code }
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case name, disabled, severities, limits, treatsPublicApiAsUsed, scopedOverrides
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? Self.defaultName
        disabled = Set(try container.decodeIfPresent([String].self, forKey: .disabled) ?? Array(Self.defaultDisabledCodes))
        severities = try container.decodeIfPresent([String: String].self, forKey: .severities) ?? [:]
        limits = try container.decodeIfPresent([String: Int].self, forKey: .limits) ?? [:]
        treatsPublicApiAsUsed = try container.decodeIfPresent(Bool.self, forKey: .treatsPublicApiAsUsed) ?? true
        scopedOverrides = try container.decodeIfPresent([ScopedOverride].self, forKey: .scopedOverrides) ?? []
        let known = Set(CodingKeys.allCases.map(\.stringValue))
        var others: [String: Data] = [:]
        let everything = try decoder.container(keyedBy: SectionKey.self)
        for key in everything.allKeys where !known.contains(key.stringValue) {
            guard let raw = try? everything.decode(RawJSON.self, forKey: key) else { continue }
            others[key.stringValue] = raw.data
        }
        sections = others
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(disabled.sorted(), forKey: .disabled)
        try container.encode(severities, forKey: .severities)
        try container.encode(limits, forKey: .limits)
        try container.encode(treatsPublicApiAsUsed, forKey: .treatsPublicApiAsUsed)
        try container.encode(scopedOverrides, forKey: .scopedOverrides)
        var others = encoder.container(keyedBy: SectionKey.self)
        for (name, data) in sections.sorted(by: { $0.key < $1.key }) {
            guard let key = SectionKey(stringValue: name), let raw = RawJSON(data: data) else { continue }
            try others.encode(raw, forKey: key)
        }
    }

    private struct SectionKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// Any JSON value, kept so that a section this code does not model survives a round trip.
    private enum RawJSON: Codable {
        case null
        case bool(Bool)
        case integer(Int)
        case number(Double)
        case string(String)
        case array([RawJSON])
        case object([String: RawJSON])

        init?(data: Data) {
            guard let value = try? JSONDecoder().decode(RawJSON.self, from: data) else { return nil }
            self = value
        }

        var data: Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return (try? encoder.encode(self)) ?? Data()
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null }
            else if let value = try? container.decode(Bool.self) { self = .bool(value) }
            else if let value = try? container.decode(Int.self) { self = .integer(value) }
            else if let value = try? container.decode(Double.self) { self = .number(value) }
            else if let value = try? container.decode(String.self) { self = .string(value) }
            else if let value = try? container.decode([RawJSON].self) { self = .array(value) }
            else { self = .object(try container.decode([String: RawJSON].self)) }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .null: try container.encodeNil()
            case .bool(let value): try container.encode(value)
            case .integer(let value): try container.encode(value)
            case .number(let value): try container.encode(value)
            case .string(let value): try container.encode(value)
            case .array(let value): try container.encode(value)
            case .object(let value): try container.encode(value)
            }
        }
    }
}
