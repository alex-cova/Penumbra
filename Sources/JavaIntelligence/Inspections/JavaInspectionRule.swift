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
    case controlFlow
    case namingConventions

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
        case .controlFlow: return "Control flow issues"
        case .namingConventions: return "Naming conventions"
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
    case redundantIfStatement
    case simplifiableConditional
    case identicalBranches
    case duplicateSwitchBranches
    case pointlessBooleanExpression
    case constantCondition
    case infiniteLoop
    case loopDoesNotLoop
    case assertWithSideEffects
    case constantAssertCondition
    case nonShortCircuitBoolean
    case comparableWithoutEquals
    case iteratorHasNextCallsNext
    case mismatchedStringCase
    case missingWhitespaceInConcatenation
    case classNewInstance
    case roundingOfIntegers
    case integerDivisionInFloatingContext
    case stringConcatenationInFormat
    case collectionAddedToItself
    case resultOfCallIgnored
    case overwrittenElement
    case infiniteRecursion
    case duplicatedDelimiters
    case classNamingConvention
    case methodNamingConvention
    case fieldNamingConvention
    case localVariableNamingConvention
    case parameterNamingConvention
    case typeParameterNamingConvention
    case enumConstantNamingConvention
    case nonConstantFieldNamedLikeConstant
    case methodNameSameAsClass

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
        .redundantIfStatement: Info(code: "redundant-if-statement", title: "Redundant 'if' statement", group: .controlFlow, severity: .weakWarning, summary: "Reports 'if (c) return true; else return false;', which is 'return c;'."),
        .simplifiableConditional: Info(code: "simplifiable-conditional-expression", title: "Simplifiable conditional expression", group: .controlFlow, severity: .weakWarning, summary: "Reports 'c ? true : false' and 'c ? false : true'."),
        .identicalBranches: Info(code: "identical-branches", title: "'if' or '?:' with identical branches", group: .controlFlow, severity: .warning, summary: "Reports a conditional whose two branches are the same code."),
        .duplicateSwitchBranches: Info(code: "duplicate-switch-branches", title: "Duplicate branches in 'switch'", group: .controlFlow, severity: .weakWarning, summary: "Reports arrow-form switch rules with the same body, which could share one 'case' list."),
        .pointlessBooleanExpression: Info(code: "pointless-boolean-expression", title: "Pointless boolean expression", group: .controlFlow, severity: .warning, summary: "Reports 'x && true', 'x == false' and similar, where the literal changes nothing or decides the result."),
        .constantCondition: Info(code: "constant-condition", title: "Constant condition", group: .controlFlow, severity: .warning, summary: "Reports 'if (true)', 'while (false)' and '?:' on a boolean literal."),
        .infiniteLoop: Info(code: "infinite-loop", title: "Infinite loop statement", group: .controlFlow, severity: .warning, summary: "Reports 'while (true)' and 'for (;;)' with no break, return or throw that leaves it."),
        .loopDoesNotLoop: Info(code: "loop-does-not-loop", title: "Loop does not loop", group: .controlFlow, severity: .warning, summary: "Reports a loop whose body always ends with break, return or throw."),
        .assertWithSideEffects: Info(code: "assert-side-effects", title: "'assert' statement with side effects", group: .probableBugs, severity: .warning, summary: "Reports assignments and increments in an assert condition, which vanish when assertions are off."),
        .constantAssertCondition: Info(code: "constant-assert-condition", title: "Constant condition in 'assert' statement", group: .probableBugs, severity: .weakWarning, summary: "Reports 'assert true', which checks nothing."),
        .nonShortCircuitBoolean: Info(code: "non-short-circuit-boolean", title: "Non-short-circuit boolean expression", group: .probableBugs, severity: .warning, summary: "Reports '&' and '|' between booleans, which evaluate both sides."),
        .comparableWithoutEquals: Info(code: "comparable-without-equals", title: "'Comparable' implemented but 'equals()' not overridden", group: .probableBugs, severity: .warning, summary: "Reports a class with compareTo() and no equals(), so sorted and hashed collections disagree."),
        .iteratorHasNextCallsNext: Info(code: "iterator-hasnext-calls-next", title: "'Iterator.hasNext()' which calls 'next()'", group: .probableBugs, severity: .warning, summary: "Reports hasNext() that advances the iterator."),
        .mismatchedStringCase: Info(code: "mismatched-string-case", title: "Mismatched case in 'String' operation", group: .probableBugs, severity: .warning, summary: "Reports toLowerCase().contains(\"ABC\") and similar, which can never match."),
        .missingWhitespaceInConcatenation: Info(code: "missing-whitespace-in-concatenation", title: "Whitespace may be missing in string concatenation", group: .probableBugs, severity: .warning, summary: "Reports two string literals on different lines that join a word to the next."),
        .classNewInstance: Info(code: "class-new-instance", title: "Unsafe call to 'Class.newInstance()'", group: .probableBugs, severity: .warning, summary: "Reports Class.newInstance(), which rethrows constructor exceptions unchecked."),
        .roundingOfIntegers: Info(code: "rounding-of-integers", title: "Math rounding of an integer", group: .probableBugs, severity: .warning, summary: "Reports Math.floor/ceil/round/rint on an integer or an integer division."),
        .integerDivisionInFloatingContext: Info(code: "integer-division-in-floating-context", title: "Integer division in floating-point context", group: .probableBugs, severity: .warning, summary: "Reports 'a / b' on integers stored in a double or float, which truncates first."),
        .stringConcatenationInFormat: Info(code: "string-concatenation-in-format", title: "String concatenation as argument to 'format()' call", group: .probableBugs, severity: .warning, summary: "Reports a format string built with '+', which breaks on a stray '%'."),
        .collectionAddedToItself: Info(code: "collection-added-to-itself", title: "Collection added to itself", group: .probableBugs, severity: .warning, summary: "Reports 'list.add(list)' and 'list.addAll(list)'."),
        .resultOfCallIgnored: Info(code: "result-of-call-ignored", title: "Result of method call ignored", group: .probableBugs, severity: .warning, summary: "Reports String, Math and BigDecimal calls whose result is dropped, as in 's.trim();'."),
        .overwrittenElement: Info(code: "overwritten-element", title: "Overwritten array or map element", group: .probableBugs, severity: .warning, summary: "Reports 'a[i] = x; a[i] = y;' and two puts of one key in a row."),
        .infiniteRecursion: Info(code: "infinite-recursion", title: "Infinite recursion", group: .probableBugs, severity: .warning, summary: "Reports a method that calls itself with its own parameters and has no way out."),
        .duplicatedDelimiters: Info(code: "duplicated-delimiters", title: "Duplicated delimiters in 'StringTokenizer'", group: .probableBugs, severity: .warning, summary: "Reports a delimiter string that repeats a character."),
        .classNamingConvention: Info(code: "class-naming-convention", title: "Class naming convention", group: .namingConventions, severity: .weakWarning, summary: "Reports a class, interface, enum, record or annotation not named in UpperCamelCase."),
        .methodNamingConvention: Info(code: "method-naming-convention", title: "Method naming convention", group: .namingConventions, severity: .weakWarning, summary: "Reports a method not named in lowerCamelCase. Overrides and test methods are exempt."),
        .fieldNamingConvention: Info(code: "field-naming-convention", title: "Field and constant naming convention", group: .namingConventions, severity: .weakWarning, summary: "Reports a field not in lowerCamelCase, or a static final constant not in UPPER_SNAKE_CASE."),
        .localVariableNamingConvention: Info(code: "local-variable-naming-convention", title: "Local variable naming convention", group: .namingConventions, severity: .weakWarning, summary: "Reports a local variable not named in lowerCamelCase."),
        .parameterNamingConvention: Info(code: "parameter-naming-convention", title: "Method parameter naming convention", group: .namingConventions, severity: .weakWarning, summary: "Reports a method parameter not named in lowerCamelCase."),
        .typeParameterNamingConvention: Info(code: "type-parameter-naming-convention", title: "Type parameter naming convention", group: .namingConventions, severity: .weakWarning, summary: "Reports a type parameter not starting with an upper-case letter."),
        .enumConstantNamingConvention: Info(code: "enum-constant-naming-convention", title: "Enum constant naming convention", group: .namingConventions, severity: .weakWarning, summary: "Reports an enum constant not in UPPER_SNAKE_CASE."),
        .nonConstantFieldNamedLikeConstant: Info(code: "non-constant-field-named-like-constant", title: "Non-constant field with a constant's name", group: .namingConventions, severity: .weakWarning, summary: "Reports a field in UPPER_SNAKE_CASE that is not static final."),
        .methodNameSameAsClass: Info(code: "method-name-same-as-class", title: "Method name is the same as its class name", group: .namingConventions, severity: .warning, summary: "Reports a method with a return type named like its class, which is probably a misspelt constructor."),
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
