import Foundation

/// Where a rule is listed in Settings, after IntelliJ's Inspectopedia.
public enum SwiftInspectionGroup: String, CaseIterable, Sendable {
    case probableBugs
    case redundantCode
    case idioms
    case naming
    case unusedCode
    case metrics

    public var title: String {
        switch self {
        case .probableBugs: "Probable bugs"
        case .redundantCode: "Redundant code"
        case .idioms: "Swift idioms and performance"
        case .naming: "Naming conventions"
        case .unusedCode: "Unused code"
        case .metrics: "Code metrics"
        }
    }
}

/// The rules the native Swift inspections ship. Each reports something the compiler does not: `swiftc`
/// already warns about an unused value, an unreachable `default` or a mutated-never `var`, and those
/// are left to it (and to SourceKit-LSP, which surfaces its diagnostics).
public enum SwiftInspectionRule: String, CaseIterable, Sendable, Hashable {
    // Probable bugs and safety
    case emptyCatch = "empty-catch"
    case identicalOperands = "identical-operands"
    case duplicateConditions = "duplicate-conditions"
    case delegateNotWeak = "delegate-not-weak"
    case forceUnwrap = "force-unwrap"
    case forceTry = "force-try"
    case forceCast = "force-cast"
    // Redundant code
    case redundantReturn = "redundant-return"
    case redundantParentheses = "redundant-parentheses"
    case redundantOptionalInitialization = "redundant-optional-init"
    case redundantVoidReturn = "redundant-void-return"
    case unneededBreak = "unneeded-break"
    case unusedClosureParameter = "unused-closure-parameter"
    case emptyStatementBody = "empty-statement-body"
    case explicitInit = "explicit-init"
    // Idioms and performance
    case countIsZero = "count-is-zero"
    case filterFirst = "filter-first"
    case sortedFirst = "sorted-first"
    case firstWhereNil = "first-where-nil"
    case leftoverPrint = "leftover-print"
    // Naming
    case typeNameCase = "type-name-case"
    case memberNameCase = "member-name-case"
    // Unused code (the compiler warns about unused locals, not about these)
    case unusedPrivateMember = "unused-private-member"
    /// Needs the whole project: asks the index whether the name is mentioned anywhere else. Run by Inspect Code.
    case unusedDeclaration = "unused-declaration"
    // Redundant code
    /// Needs the index: reports an import whose module is known and shows nothing the file mentions.
    /// Conservative by construction (re-exports, operators, retroactive conformances, testable,
    /// scoped and unknown modules are never reported), and runs from a save, an open or a profile
    /// change as well as from Inspect Code.
    case unusedImport = "unused-import"
    // Metrics
    case longFunction = "long-function"
    case highComplexity = "high-complexity"
    case manyParameters = "many-parameters"

    public var code: String { rawValue }

    public init?(code: String) { self.init(rawValue: code) }

    public var group: SwiftInspectionGroup {
        switch self {
        case .emptyCatch, .identicalOperands, .duplicateConditions, .delegateNotWeak, .forceUnwrap, .forceTry, .forceCast:
            .probableBugs
        case .redundantReturn, .redundantParentheses, .redundantOptionalInitialization,
             .redundantVoidReturn, .unneededBreak, .unusedClosureParameter, .emptyStatementBody, .explicitInit,
             .unusedImport:
            .redundantCode
        case .countIsZero, .filterFirst, .sortedFirst, .firstWhereNil, .leftoverPrint:
            .idioms
        case .typeNameCase, .memberNameCase:
            .naming
        case .unusedPrivateMember, .unusedDeclaration:
            .unusedCode
        case .longFunction, .highComplexity, .manyParameters:
            .metrics
        }
    }

    public var title: String {
        switch self {
        case .emptyCatch: "Empty catch block"
        case .identicalOperands: "Identical operands"
        case .duplicateConditions: "Duplicate condition in an if-else chain"
        case .delegateNotWeak: "Delegate property is not weak"
        case .forceUnwrap: "Force unwrap"
        case .forceTry: "Force try"
        case .forceCast: "Force cast"
        case .redundantReturn: "Redundant return"
        case .redundantParentheses: "Redundant parentheses around a condition"
        case .redundantOptionalInitialization: "Redundant '= nil' on an optional variable"
        case .redundantVoidReturn: "Redundant '-> Void'"
        case .unneededBreak: "Unneeded 'break' at the end of a case"
        case .unusedClosureParameter: "Unused closure parameter"
        case .emptyStatementBody: "Empty statement body"
        case .explicitInit: "Explicit '.init' call"
        case .countIsZero: "'count' compared with zero"
        case .filterFirst: "'filter' followed by 'first' or 'last'"
        case .sortedFirst: "'sorted' followed by 'first' or 'last'"
        case .firstWhereNil: "'first(where:)' compared with nil"
        case .leftoverPrint: "Leftover print"
        case .typeNameCase: "Type name does not start with an uppercase letter"
        case .memberNameCase: "Member name starts with an uppercase letter"
        case .unusedPrivateMember: "Unused private declaration"
        case .unusedDeclaration: "Unused declaration"
        case .unusedImport: "Unused import"
        case .longFunction: "Long function"
        case .highComplexity: "Function is too complex"
        case .manyParameters: "Function has too many parameters"
        }
    }

    /// What the rule looks for and what it proposes, for Settings.
    public var summary: String {
        switch self {
        case .emptyCatch: "A `catch` with nothing in it, not even a comment, swallows the error."
        case .identicalOperands: "Both sides of `&&`, `||`, `<`, `>`, `-` or `/` are the same expression."
        case .duplicateConditions: "An `else if` repeats a condition of the same chain, so it can never run."
        case .delegateNotWeak: "A property named `delegate` in a class, not marked `weak` or `unowned`, is a retain cycle waiting to happen."
        case .forceUnwrap: "`x!` crashes when `x` is nil."
        case .forceTry: "`try!` crashes when the call throws."
        case .forceCast: "`as!` crashes when the cast fails."
        case .redundantReturn: "A body that is one expression returns it without `return`."
        case .redundantParentheses: "`if (x)` does not need the parentheses."
        case .redundantOptionalInitialization: "An optional `var` starts as nil without `= nil`."
        case .redundantVoidReturn: "A function returns Void without saying so."
        case .unneededBreak: "A Swift `case` does not fall through, so a trailing `break` does nothing."
        case .unusedClosureParameter: "A named closure parameter that the body never reads can be `_`."
        case .emptyStatementBody: "An `if` whose body is empty. (An empty `for` or `while` is often the way to drain a sequence, so those are not reported.)"
        case .explicitInit: "`Foo.init(…)` is `Foo(…)`."
        case .countIsZero: "`x.count == 0` is `x.isEmpty`, which does not count."
        case .filterFirst: "`x.filter { … }.first` builds a whole array to take one element; `x.first { … }` stops at the match."
        case .sortedFirst: "`x.sorted().first` sorts to find the smallest; `x.min()` does not."
        case .firstWhereNil: "`x.first(where: p) != nil` is `x.contains(where: p)`."
        case .leftoverPrint: "A `print`, `debugPrint` or `dump` call left in the code."
        case .typeNameCase: "Types are named in UpperCamelCase."
        case .memberNameCase: "Properties and functions are named in lowerCamelCase."
        case .unusedPrivateMember: "A `private` or `fileprivate` function, property or type whose name appears nowhere else in its file, where nothing outside the file can use it."
        case .unusedDeclaration: "An internal type, function or property whose name appears nowhere else in the project. Public API, attributed declarations, overrides, tests and protocol witnesses are left alone. Searches the whole project, so it runs from Inspect Code."
        case .unusedImport: "An `import` whose module the index knows and nothing in the file mentions — not in code, comments or strings. Its own module, `@testable`, `@_exported`, scoped (`import struct X.Y`), re-exporting, operator-declaring, retroactively conforming and unknown (SDK, dependencies) modules are never reported. Offers Remove import, also batched from Inspect Code."
        case .longFunction: "A function longer than the limit."
        case .highComplexity: "A function with more decision points than the limit."
        case .manyParameters: "A function with more parameters than the limit."
        }
    }

    public var defaultSeverity: SwiftInspection.Severity {
        switch self {
        case .emptyCatch, .identicalOperands, .duplicateConditions: .warning
        case .delegateNotWeak, .forceUnwrap, .forceTry, .forceCast: .weakWarning
        case .typeNameCase, .memberNameCase: .weakWarning
        case .longFunction, .highComplexity, .manyParameters: .weakWarning
        default: .weakWarning
        }
    }

    /// Off unless the user turns them on: opinionated (a codebase may force-unwrap on purpose, a command
    /// line tool prints), unprovable from syntax (`count` on a type with no `isEmpty`) or about size (every large function would be listed).
    public var isEnabledByDefault: Bool {
        switch self {
        case .forceUnwrap, .forceTry, .forceCast, .leftoverPrint, .countIsZero, .longFunction, .highComplexity, .manyParameters: false
        default: true
        }
    }

    /// The SwiftLint rule this one corresponds to, so `// swiftlint:disable:next …` silences it too.
    public var swiftLintName: String? {
        switch self {
        case .forceUnwrap: "force_unwrapping"
        case .forceTry: "force_try"
        case .forceCast: "force_cast"
        case .emptyCatch: nil
        case .countIsZero: "empty_count"
        case .filterFirst: "first_where"
        case .firstWhereNil: "contains_over_first_not_nil"
        case .sortedFirst: "sorted_first_last"
        case .redundantOptionalInitialization: "redundant_optional_initialization"
        case .redundantVoidReturn: "redundant_void_return"
        case .unneededBreak: "unneeded_break_in_switch"
        case .unusedClosureParameter: "unused_closure_parameter"
        case .explicitInit: "explicit_init"
        case .redundantReturn: "implicit_return"
        case .delegateNotWeak: "weak_delegate"
        case .leftoverPrint: "no_print_in_production"
        case .typeNameCase: "type_name"
        case .memberNameCase: "identifier_name"
        case .longFunction: "function_body_length"
        case .highComplexity: "cyclomatic_complexity"
        case .manyParameters: "function_parameter_count"
        case .identicalOperands: "identical_operands"
        case .duplicateConditions: "duplicate_conditions"
        case .unusedPrivateMember, .unusedDeclaration: "unused_declaration"
        case .unusedImport: "unused_import"
        case .emptyStatementBody, .redundantParentheses: nil
        }
    }

    /// Rules that need the rest of the project, and so run from Inspect Code and not as you type.
    public var isProjectWide: Bool { self == .unusedDeclaration }

    /// Rules that ask the index about the rest of the project. They run from Inspect Code and from
    /// a save, an open or a profile change — never on a keystroke — with one pass per document in
    /// flight and a newer save cancelling the older one.
    public var needsIndex: Bool { self == .unusedDeclaration || self == .unusedImport }

    /// Whether the rule offers a quick fix at all.
    public var hasFixes: Bool {
        switch self {
        case .redundantReturn, .redundantParentheses, .redundantOptionalInitialization,
             .redundantVoidReturn, .unneededBreak, .unusedClosureParameter, .explicitInit,
             .countIsZero, .filterFirst, .sortedFirst, .firstWhereNil, .unusedImport:
            true
        default:
            false
        }
    }
}

/// The thresholds of the metric rules.
public struct SwiftInspectionLimits: Sendable, Hashable {
    public var functionLines: Int
    public var complexity: Int
    public var parameters: Int

    public init(functionLines: Int = 80, complexity: Int = 15, parameters: Int = 6) {
        self.functionLines = functionLines
        self.complexity = complexity
        self.parameters = parameters
    }

    public static let standard = SwiftInspectionLimits()
}

/// What the user chose, as deviations from the defaults.
public struct SwiftInspectionOptions: Sendable, Hashable {
    /// Rules that are on by default and switched off.
    public var disabled: Set<String>
    /// Rules that are off by default and switched on.
    public var enabled: Set<String>
    public var severities: [String: SwiftInspection.Severity]
    public var limits: SwiftInspectionLimits
    /// Whether the project-wide rules leave `public` and `open` declarations alone (their users may be outside).
    public var treatsPublicApiAsUsed: Bool

    public init(
        disabled: Set<String> = [], enabled: Set<String> = [],
        severities: [String: SwiftInspection.Severity] = [:], limits: SwiftInspectionLimits = .standard,
        treatsPublicApiAsUsed: Bool = true
    ) {
        self.disabled = disabled
        self.enabled = enabled
        self.severities = severities
        self.limits = limits
        self.treatsPublicApiAsUsed = treatsPublicApiAsUsed
    }

    public static let standard = SwiftInspectionOptions()

    public func isEnabled(_ rule: SwiftInspectionRule) -> Bool {
        rule.isEnabledByDefault ? !disabled.contains(rule.code) : enabled.contains(rule.code)
    }

    public func severity(of rule: SwiftInspectionRule) -> SwiftInspection.Severity {
        severities[rule.code] ?? rule.defaultSeverity
    }

    public var enabledRules: Set<SwiftInspectionRule> {
        Set(SwiftInspectionRule.allCases.filter(isEnabled))
    }
}
