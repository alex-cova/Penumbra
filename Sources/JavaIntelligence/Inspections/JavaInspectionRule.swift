import Foundation

/// Inspectopedia-style category a rule is listed under in Settings.
public enum JavaInspectionGroup: String, CaseIterable, Sendable {
    case probableBugs
    case verboseCode
    case declarationRedundancy
    case imports
    case inheritance
    case classStructure
    case compilerIssues

    public var title: String {
        switch self {
        case .probableBugs: return "Probable bugs"
        case .verboseCode: return "Verbose or redundant code constructs"
        case .declarationRedundancy: return "Declaration redundancy"
        case .imports: return "Imports"
        case .inheritance: return "Inheritance issues"
        case .classStructure: return "Class structure"
        case .compilerIssues: return "Compiler issues"
        }
    }
}

public enum JavaInspectionRule: String, CaseIterable, Sendable {
    case unusedImport
    case duplicateImport
    case unresolvedImport
    case missingOverride
    case unresolvedType
    case classFileNameMismatch
    case stringComparisonIdentity
    case numberComparisonIdentity
    case arrayComparisonIdentity
    case emptyStatementBody
    case selfAssignment
    case expressionComparedToItself
    case mathRandomCastToInt
    case throwableNotThrown
    case resultOfObjectAllocationIgnored
    case stringBuilderCharArgument
    case arrayObjectMethodCall
    case equalsHashCodePair
    case covariantEquals
    case equalInsteadOfEquals
    case subtractionInCompareTo
    case suspiciousIndentation
    case unnecessaryReturn
    case unnecessaryContinue
    case unnecessaryBreak
    case unnecessaryLabelOnBreak
    case unnecessaryLabelOnContinue
    case concatenationWithEmptyString
    case manualMinMax
    case unnecessarilyEscapedCharacter
    case unusedLabel
    case duplicateThrows
    case emptyClassInitializer

    private struct Info {
        let code: String
        let title: String
        let group: JavaInspectionGroup
        let severity: JavaInspection.Severity
        let summary: String
    }

    private static let table: [JavaInspectionRule: Info] = [
        .unusedImport: Info(code: "unused-import", title: "Unused import", group: .imports, severity: .warning, summary: "Reports imports that nothing in the file uses."),
        .duplicateImport: Info(code: "duplicate-import", title: "Duplicate import", group: .imports, severity: .warning, summary: "Reports an import that appears more than once."),
        .unresolvedImport: Info(code: "unresolved-import", title: "Unresolved import", group: .imports, severity: .warning, summary: "Reports imports that resolve to no known class."),
        .missingOverride: Info(code: "missing-override", title: "Missing '@Override' annotation", group: .inheritance, severity: .warning, summary: "Reports methods that override a supertype method without '@Override'."),
        .unresolvedType: Info(code: "unresolved-type", title: "Unresolved type", group: .compilerIssues, severity: .warning, summary: "Reports type names that are neither declared, imported nor in scope."),
        .classFileNameMismatch: Info(code: "class-file-name-mismatch", title: "Class name does not match file name", group: .classStructure, severity: .warning, summary: "Reports a public top-level class whose name differs from its file name."),
        .stringComparisonIdentity: Info(code: "string-comparison-identity", title: "String comparison using '==' instead of 'equals()'", group: .probableBugs, severity: .warning, summary: "Reports '==' and '!=' used to compare strings, which compares references."),
        .numberComparisonIdentity: Info(code: "number-comparison-identity", title: "Number comparison using '==' instead of 'equals()'", group: .probableBugs, severity: .warning, summary: "Reports '==' and '!=' used to compare boxed numbers, which compares references."),
        .arrayComparisonIdentity: Info(code: "array-comparison-identity", title: "Array comparison using '==' instead of 'Arrays.equals()'", group: .probableBugs, severity: .warning, summary: "Reports '==' and '!=' used to compare the contents of two arrays."),
        .emptyStatementBody: Info(code: "empty-statement-body", title: "Statement with empty body", group: .probableBugs, severity: .warning, summary: "Reports if, while, for and do statements whose body is a lone ';'."),
        .selfAssignment: Info(code: "self-assignment", title: "Variable is assigned to itself", group: .probableBugs, severity: .warning, summary: "Reports assignments such as 'x = x;'."),
        .expressionComparedToItself: Info(code: "expression-compared-to-itself", title: "Expression is compared to itself", group: .probableBugs, severity: .warning, summary: "Reports comparisons such as 'a == a' and 'a.equals(a)'."),
        .mathRandomCastToInt: Info(code: "math-random-cast-to-int", title: "'Math.random()' cast to 'int'", group: .probableBugs, severity: .warning, summary: "Reports '(int) Math.random()', which is always 0."),
        .throwableNotThrown: Info(code: "throwable-not-thrown", title: "'Throwable' not thrown", group: .probableBugs, severity: .warning, summary: "Reports exceptions that are created and then dropped."),
        .resultOfObjectAllocationIgnored: Info(code: "result-of-object-allocation-ignored", title: "Result of object allocation ignored", group: .probableBugs, severity: .warning, summary: "Reports 'new X();' statements that discard the new object."),
        .stringBuilderCharArgument: Info(code: "string-builder-char-argument", title: "'StringBuilder' constructor call with 'char' argument", group: .probableBugs, severity: .warning, summary: "Reports 'new StringBuilder('c')', which sets the capacity instead of the content."),
        .arrayObjectMethodCall: Info(code: "array-object-method-call", title: "'equals()', 'hashCode()' or 'toString()' called on array", group: .probableBugs, severity: .warning, summary: "Reports Object methods called on an array, which do not look at its elements."),
        .equalsHashCodePair: Info(code: "equals-hashcode-pair", title: "'equals()' and 'hashCode()' not paired", group: .probableBugs, severity: .warning, summary: "Reports a class that overrides only one of 'equals()' and 'hashCode()'."),
        .covariantEquals: Info(code: "covariant-equals", title: "Covariant 'equals()'", group: .probableBugs, severity: .warning, summary: "Reports 'equals()' declared with a parameter type other than Object."),
        .equalInsteadOfEquals: Info(code: "equal-instead-of-equals", title: "'equal()' instead of 'equals()'", group: .probableBugs, severity: .warning, summary: "Reports a one-parameter method named 'equal'."),
        .subtractionInCompareTo: Info(code: "subtraction-in-compareto", title: "Subtraction in 'compareTo()'", group: .probableBugs, severity: .warning, summary: "Reports 'a - b' returned from 'compareTo()' or 'compare()', which can overflow."),
        .suspiciousIndentation: Info(code: "suspicious-indentation", title: "Suspicious indentation after control statement without braces", group: .probableBugs, severity: .warning, summary: "Reports a statement indented as if it were in the body of the control statement above it."),
        .unnecessaryReturn: Info(code: "unnecessary-return", title: "Unnecessary 'return' statement", group: .verboseCode, severity: .weakWarning, summary: "Reports 'return;' as the last statement of a void method or constructor."),
        .unnecessaryContinue: Info(code: "unnecessary-continue", title: "Unnecessary 'continue' statement", group: .verboseCode, severity: .weakWarning, summary: "Reports 'continue;' as the last statement of a loop body."),
        .unnecessaryBreak: Info(code: "unnecessary-break", title: "Unnecessary 'break' statement", group: .verboseCode, severity: .weakWarning, summary: "Reports 'break;' at the end of an arrow-form switch rule."),
        .unnecessaryLabelOnBreak: Info(code: "unnecessary-label-on-break", title: "Unnecessary label on 'break' statement", group: .verboseCode, severity: .weakWarning, summary: "Reports 'break label;' where a plain 'break;' leaves the same loop."),
        .unnecessaryLabelOnContinue: Info(code: "unnecessary-label-on-continue", title: "Unnecessary label on 'continue' statement", group: .verboseCode, severity: .weakWarning, summary: "Reports 'continue label;' where a plain 'continue;' continues the same loop."),
        .concatenationWithEmptyString: Info(code: "concatenation-with-empty-string", title: "Concatenation with empty string", group: .verboseCode, severity: .weakWarning, summary: "Reports an empty string literal used as an operand of '+'."),
        .manualMinMax: Info(code: "manual-min-max", title: "Manual min/max calculation", group: .verboseCode, severity: .weakWarning, summary: "Reports 'a > b ? a : b' on numbers, which 'Math.max()' expresses."),
        .unnecessarilyEscapedCharacter: Info(code: "unnecessarily-escaped-character", title: "Unnecessarily escaped character", group: .verboseCode, severity: .weakWarning, summary: "Reports \\' in string literals and \\\" in char literals."),
        .unusedLabel: Info(code: "unused-label", title: "Unused label", group: .declarationRedundancy, severity: .weakWarning, summary: "Reports labels that no break or continue refers to."),
        .duplicateThrows: Info(code: "duplicate-throws", title: "Duplicate throws", group: .declarationRedundancy, severity: .weakWarning, summary: "Reports an exception listed twice in a throws clause."),
        .emptyClassInitializer: Info(code: "empty-class-initializer", title: "Empty class initializer", group: .declarationRedundancy, severity: .weakWarning, summary: "Reports initializer blocks with no statements."),
    ]

    private static let byCode: [String: JavaInspectionRule] = Dictionary(
        uniqueKeysWithValues: allCases.map { ($0.info.code, $0) }
    )

    private var info: Info { Self.table[self]! }

    /// The id carried by `JavaInspection.id` and `Diagnostic.code`, and the name that
    /// `@SuppressWarnings` / `//noinspection` use.
    public var code: String { info.code }
    public var title: String { info.title }
    public var summary: String { info.summary }
    public var group: JavaInspectionGroup { info.group }
    public var defaultSeverity: JavaInspection.Severity { info.severity }

    public init?(code: String) {
        guard let rule = Self.byCode[code] else { return nil }
        self = rule
    }
}
