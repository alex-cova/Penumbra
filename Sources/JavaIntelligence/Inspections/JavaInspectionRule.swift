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
    case errorHandling
    case codeMaturity

    public var title: String {
        switch self {
        case .probableBugs: return "Probable bugs"
        case .verboseCode: return "Verbose or redundant code constructs"
        case .declarationRedundancy: return "Declaration redundancy"
        case .imports: return "Imports"
        case .inheritance: return "Inheritance issues"
        case .classStructure: return "Class structure"
        case .compilerIssues: return "Compiler issues"
        case .errorHandling: return "Error handling"
        case .codeMaturity: return "Code maturity"
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
    case accessStaticViaInstance
    case redundantArrayCreation
    case textLabelInSwitch
    case redundantClose
    case replacementHasNoEffect
    case unnecessaryDefaultForEnumSwitch
    case redundantFileCreation
    case emptyCatchBlock
    case catchOfThrowable
    case caughtExceptionRethrown
    case jumpOutOfFinally
    case emptyFinallyBlock
    case emptyTryBlock
    case printStackTraceCall
    case systemOutErr
    case systemGcCall
    case obsoleteCollection
    case finalizeDeclared

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
        .accessStaticViaInstance: Info(code: "access-static-via-instance", title: "Access static member via instance reference", group: .declarationRedundancy, severity: .warning, summary: "Reports static methods called through a variable instead of the class."),
        .redundantArrayCreation: Info(code: "redundant-array-creation", title: "Redundant array creation for calling varargs method", group: .verboseCode, severity: .weakWarning, summary: "Reports 'new T[]{a, b}' passed where the varargs method accepts 'a, b'."),
        .textLabelInSwitch: Info(code: "text-label-in-switch", title: "Text label in 'switch' statement", group: .probableBugs, severity: .warning, summary: "Reports an unused label directly inside an old-style switch, often a mistyped 'case' or 'default'."),
        .redundantClose: Info(code: "redundant-close", title: "Redundant 'close()'", group: .declarationRedundancy, severity: .weakWarning, summary: "Reports 'close()' as the last statement of a try-with-resources body."),
        .replacementHasNoEffect: Info(code: "replacement-has-no-effect", title: "Replacement operation has no effect", group: .verboseCode, severity: .warning, summary: "Reports String 'replace' calls that replace text with itself."),
        .unnecessaryDefaultForEnumSwitch: Info(code: "unnecessary-default-for-enum-switch", title: "Unnecessary 'default' for enum 'switch'", group: .verboseCode, severity: .weakWarning, summary: "Reports a 'default' rule in an arrow-form switch that already covers every constant of an enum declared in the file."),
        .redundantFileCreation: Info(code: "redundant-file-creation", title: "Redundant 'File' instance creation", group: .verboseCode, severity: .weakWarning, summary: "Reports 'new FileReader(new File(path))' where the stream or reader takes the path itself."),
        .emptyCatchBlock: Info(code: "empty-catch-block", title: "Empty 'catch' block", group: .errorHandling, severity: .warning, summary: "Reports a catch block with no statements and no comment, which swallows the exception."),
        .catchOfThrowable: Info(code: "catch-of-throwable", title: "'catch' of 'Throwable'", group: .errorHandling, severity: .weakWarning, summary: "Reports catching Throwable, which also catches errors such as OutOfMemoryError."),
        .caughtExceptionRethrown: Info(code: "caught-exception-rethrown", title: "Caught exception is immediately rethrown", group: .errorHandling, severity: .warning, summary: "Reports a catch block whose only statement rethrows the exception unchanged."),
        .jumpOutOfFinally: Info(code: "jump-out-of-finally", title: "'return' or 'throw' inside 'finally'", group: .errorHandling, severity: .warning, summary: "Reports return and throw in a finally block, which discard any pending exception."),
        .emptyFinallyBlock: Info(code: "empty-finally-block", title: "Empty 'finally' block", group: .errorHandling, severity: .warning, summary: "Reports a finally block with no statements."),
        .emptyTryBlock: Info(code: "empty-try-block", title: "Empty 'try' block", group: .errorHandling, severity: .warning, summary: "Reports a try block with no statements."),
        .printStackTraceCall: Info(code: "print-stack-trace", title: "Call to 'printStackTrace()'", group: .codeMaturity, severity: .weakWarning, summary: "Reports printStackTrace() and Thread.dumpStack(), which bypass logging."),
        .systemOutErr: Info(code: "system-out-err", title: "Use of 'System.out' or 'System.err'", group: .codeMaturity, severity: .weakWarning, summary: "Reports System.out and System.err, which bypass logging."),
        .systemGcCall: Info(code: "system-gc-call", title: "Call to 'System.gc()' or 'Runtime.gc()'", group: .codeMaturity, severity: .warning, summary: "Reports explicit garbage-collection requests."),
        .obsoleteCollection: Info(code: "obsolete-collection", title: "Use of obsolete collection type", group: .codeMaturity, severity: .weakWarning, summary: "Reports new Vector, Hashtable and Stack; ArrayList, HashMap and ArrayDeque replace them."),
        .finalizeDeclared: Info(code: "finalize-declared", title: "'finalize()' declared", group: .codeMaturity, severity: .warning, summary: "Reports finalize(), which is deprecated for removal."),
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
