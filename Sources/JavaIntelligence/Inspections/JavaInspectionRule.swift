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
    case performance
    case javadoc

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
        case .performance: return "Performance"
        case .javadoc: return "Javadoc"
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
    case sizeComparisonWithZero
    case redundantTypeCast
    case deprecatedBoxedConstructor
    case deprecatedApiUsage
    case equalsEmptyString
    case explicitTypeArguments
    case stringConcatenationInLoop
    case localCanBeFinal
    case unusedAssignment
    case mismatchedCollectionQueryUpdate
    case unusedPrivateMember
    case forCanBeForeach
    case tryFinallyCanBeTryWithResources
    case cyclomaticComplexity
    case nestingDepth
    case parameterCount
    case methodLength
    case classLength
    case javadocMissingParam
    case javadocMissingReturn
    case javadocInvalidParam
    case nullDereference
    case nullableDereference
    case constantConditionFlow
    case redundantNullCheck
    case unreachableCode
    case resourceNotClosed
    case unusedDeclaration
    case declarationAccessCanBeWeaker
    case methodCanBeVoid
    case parameterAlwaysSameValue
    case utilityClassWithPublicConstructor
    case publicField
    case missingSerialVersionUID
    case cloneWithoutCloneable
    case finalMethodInFinalClass
    case protectedMemberInFinalClass
    case classMayBeInterface
    case redundantLocalVariable
    case redundantStringOperation
    case declarationUsesConcreteClass
    case staticViaSubclass
    case anonymousCanBeLambda
    case overridableMethodCalledInConstructor
    case synchronizationOnStringLiteral
    case synchronizationOnThis
    case waitNotInLoop
    case sortedCollectionNonComparable
    case suspiciousToArray
    case listRemoveInLoop

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
        .sizeComparisonWithZero: Info(code: "size-comparison-with-zero", title: "'size()' or 'length()' compared with zero", group: .verboseCode, severity: .weakWarning, summary: "Reports 'c.size() == 0' and similar where the type has 'isEmpty()'."),
        .redundantTypeCast: Info(code: "redundant-type-cast", title: "Redundant type cast", group: .verboseCode, severity: .weakWarning, summary: "Reports '(T) x' where x is already declared as T."),
        .deprecatedBoxedConstructor: Info(code: "deprecated-boxed-constructor", title: "Deprecated boxed-type constructor", group: .codeMaturity, severity: .warning, summary: "Reports 'new Integer(x)' and the other wrapper constructors, deprecated for removal; valueOf() replaces them."),
        .deprecatedApiUsage: Info(code: "deprecated-api-usage", title: "Deprecated API usage", group: .codeMaturity, severity: .warning, summary: "Reports a call to a method the library marks @Deprecated."),
        .equalsEmptyString: Info(code: "equals-empty-string", title: "'equals(\"\")' call", group: .verboseCode, severity: .weakWarning, summary: "Reports 's.equals(\"\")', which 's.isEmpty()' states directly."),
        .explicitTypeArguments: Info(code: "explicit-type-arguments", title: "Explicit type arguments can be replaced with '<>'", group: .verboseCode, severity: .weakWarning, summary: "Reports 'new ArrayList<String>()' assigned to a 'List<String>'."),
        .stringConcatenationInLoop: Info(code: "string-concatenation-in-loop", title: "String concatenation in a loop", group: .performance, severity: .weakWarning, summary: "Reports 's += x' on a String inside a loop, which copies the string each pass."),
        .localCanBeFinal: Info(code: "local-can-be-final", title: "Local variable can be final", group: .declarationRedundancy, severity: .weakWarning, summary: "Reports a local variable that is initialized once and never assigned again."),
        .unusedAssignment: Info(code: "unused-assignment", title: "Unused assignment", group: .probableBugs, severity: .warning, summary: "Reports a value assigned to a local that is overwritten or goes out of scope before it is read."),
        .mismatchedCollectionQueryUpdate: Info(code: "mismatched-collection-query-update", title: "Mismatched query and update of collection", group: .probableBugs, severity: .warning, summary: "Reports a collection or StringBuilder that is only queried but never updated, or only updated but never queried."),
        .unusedPrivateMember: Info(code: "unused-private-member", title: "Unused private member", group: .declarationRedundancy, severity: .warning, summary: "Reports a private field, method, constructor or nested class that nothing in the file uses."),
        .forCanBeForeach: Info(code: "for-can-be-foreach", title: "'for' loop can be replaced with enhanced 'for'", group: .verboseCode, severity: .weakWarning, summary: "Reports an index or iterator loop that only reads each element."),
        .tryFinallyCanBeTryWithResources: Info(code: "try-finally-can-be-twr", title: "'try' / 'finally' can use try-with-resources", group: .verboseCode, severity: .weakWarning, summary: "Reports a resource closed in 'finally' that try-with-resources would close."),
        .cyclomaticComplexity: Info(code: "cyclomatic-complexity", title: "Overly complex method", group: .classStructure, severity: .weakWarning, summary: "Reports a method whose cyclomatic complexity (decision points plus one) exceeds the limit."),
        .nestingDepth: Info(code: "nesting-depth", title: "Overly nested method", group: .classStructure, severity: .weakWarning, summary: "Reports a method with control structures nested deeper than the limit."),
        .parameterCount: Info(code: "parameter-count", title: "Method with too many parameters", group: .classStructure, severity: .weakWarning, summary: "Reports a method or constructor with more parameters than the limit."),
        .methodLength: Info(code: "method-length", title: "Overly long method", group: .classStructure, severity: .weakWarning, summary: "Reports a method longer than the limit, in lines."),
        .classLength: Info(code: "class-length", title: "Overly long class", group: .classStructure, severity: .weakWarning, summary: "Reports a class, interface, enum or record longer than the limit, in lines."),
        .javadocMissingParam: Info(code: "javadoc-missing-param", title: "Missing '@param' tag", group: .javadoc, severity: .weakWarning, summary: "Reports a parameter or type parameter a Javadoc comment does not describe."),
        .javadocMissingReturn: Info(code: "javadoc-missing-return", title: "Missing '@return' tag", group: .javadoc, severity: .weakWarning, summary: "Reports a Javadoc comment of a method that returns a value but has no '@return' tag."),
        .javadocInvalidParam: Info(code: "javadoc-invalid-param", title: "Invalid '@param' tag", group: .javadoc, severity: .warning, summary: "Reports an '@param' tag that names no parameter or type parameter of the method."),
        .nullDereference: Info(code: "null-dereference", title: "Null pointer dereference", group: .probableBugs, severity: .warning, summary: "Reports a local that is certainly null where a method is called on it or a member is read."),
        .nullableDereference: Info(code: "nullable-dereference", title: "Possible null pointer dereference", group: .probableBugs, severity: .weakWarning, summary: "Reports a local that is null on some path (a 'null' assigned in one branch, a failed null check) where a method is called on it or a member is read."),
        .constantConditionFlow: Info(code: "condition-always-constant", title: "Condition is always true or false", group: .controlFlow, severity: .warning, summary: "Reports a condition that the values assigned earlier in the method already decide."),
        .redundantNullCheck: Info(code: "redundant-null-check", title: "Redundant null check", group: .controlFlow, severity: .warning, summary: "Reports a comparison with null whose result is known from earlier assignments or checks."),
        .unreachableCode: Info(code: "unreachable-code", title: "Unreachable statement", group: .controlFlow, severity: .warning, summary: "Reports a statement after 'return', 'throw', 'break', 'continue' or an endless loop."),
        .resourceNotClosed: Info(code: "resource-not-closed", title: "Resource not closed", group: .probableBugs, severity: .warning, summary: "Reports a stream, reader or socket created with 'new' that is not closed on every path."),
        .unusedDeclaration: Info(code: "unused-declaration", title: "Unused declaration", group: .declarationRedundancy, severity: .warning, summary: "Reports a class, method or field that nothing in the project uses. Public and protected members count as used unless 'Treat public API as used' is off."),
        .declarationAccessCanBeWeaker: Info(code: "declaration-access-can-be-weaker", title: "Declaration access can be weaker", group: .declarationRedundancy, severity: .weakWarning, summary: "Reports a member that is only used inside its own top-level class and could be private."),
        .methodCanBeVoid: Info(code: "method-can-be-void", title: "Method can be made void", group: .declarationRedundancy, severity: .weakWarning, summary: "Reports a method whose return value no caller uses."),
        .parameterAlwaysSameValue: Info(code: "parameter-always-same-value", title: "Parameter always has the same value", group: .declarationRedundancy, severity: .weakWarning, summary: "Reports a parameter that every call passes the same literal for."),
        .utilityClassWithPublicConstructor: Info(code: "utility-class-with-public-constructor", title: "Utility class with a public constructor", group: .classStructure, severity: .weakWarning, summary: "Reports a class that only has static members but can be instantiated through a public constructor."),
        .publicField: Info(code: "public-field", title: "Public field", group: .classStructure, severity: .weakWarning, summary: "Reports a non-final public field, which exposes the class's state."),
        .missingSerialVersionUID: Info(code: "missing-serial-version-uid", title: "Missing 'serialVersionUID'", group: .classStructure, severity: .warning, summary: "Reports a class that implements Serializable without declaring serialVersionUID."),
        .cloneWithoutCloneable: Info(code: "clone-without-cloneable", title: "'clone()' without 'Cloneable'", group: .classStructure, severity: .warning, summary: "Reports a class that declares clone() but does not implement Cloneable."),
        .finalMethodInFinalClass: Info(code: "final-method-in-final-class", title: "'final' method in 'final' class", group: .classStructure, severity: .weakWarning, summary: "Reports a final method in a class (or record) that cannot be extended."),
        .protectedMemberInFinalClass: Info(code: "protected-member-in-final-class", title: "'protected' member in 'final' class", group: .classStructure, severity: .weakWarning, summary: "Reports a protected member of a class (or record) that cannot be extended."),
        .classMayBeInterface: Info(code: "class-may-be-interface", title: "Abstract class may be an interface", group: .classStructure, severity: .weakWarning, summary: "Reports an abstract class with only abstract methods and constants."),
        .redundantLocalVariable: Info(code: "redundant-local-variable", title: "Redundant local variable", group: .verboseCode, severity: .weakWarning, summary: "Reports a local variable that is returned or thrown right after its declaration."),
        .redundantStringOperation: Info(code: "redundant-string-operation", title: "Redundant 'String' operation", group: .verboseCode, severity: .weakWarning, summary: "Reports toString() on a String, new String(s) of a String and substring(0)."),
        .declarationUsesConcreteClass: Info(code: "declaration-uses-concrete-class", title: "Declaration uses a concrete collection class", group: .classStructure, severity: .weakWarning, summary: "Reports a local or private field declared as ArrayList, HashMap or HashSet where List, Map or Set would do."),
        .staticViaSubclass: Info(code: "static-via-subclass", title: "Static member accessed via subclass", group: .declarationRedundancy, severity: .warning, summary: "Reports a static member of a class referenced through a subclass that does not declare it."),
        .anonymousCanBeLambda: Info(code: "anonymous-can-be-lambda", title: "Anonymous class can be replaced with lambda", group: .verboseCode, severity: .weakWarning, summary: "Reports an anonymous class that implements a functional interface with one method."),
        .overridableMethodCalledInConstructor: Info(code: "overridable-method-called-in-constructor", title: "Overridable method called during object construction", group: .probableBugs, severity: .warning, summary: "Reports a constructor that calls a non-final, non-private method of its own class; a subclass override runs before the subclass is initialized."),
        .synchronizationOnStringLiteral: Info(code: "synchronization-on-string-literal", title: "Synchronization on a String literal", group: .probableBugs, severity: .warning, summary: "Reports synchronized(\"...\"): interned strings are shared by unrelated code."),
        .synchronizationOnThis: Info(code: "synchronization-on-this", title: "Synchronization on 'this'", group: .probableBugs, severity: .weakWarning, summary: "Reports synchronized(this), which lets any caller take the same lock."),
        .waitNotInLoop: Info(code: "wait-not-in-loop", title: "'wait()' not called in a loop", group: .probableBugs, severity: .warning, summary: "Reports wait() outside a loop; a wakeup can be spurious or the condition can change again."),
        .sortedCollectionNonComparable: Info(code: "sorted-collection-non-comparable", title: "Sorted collection with non-comparable elements", group: .probableBugs, severity: .warning, summary: "Reports a TreeSet, TreeMap or PriorityQueue without a comparator whose element class in this file is not Comparable."),
        .suspiciousToArray: Info(code: "suspicious-to-array", title: "Suspicious 'Collection.toArray()' call", group: .probableBugs, severity: .warning, summary: "Reports (T[]) c.toArray(), which always fails, and toArray(new T[0]) with an array type that cannot hold the elements."),
        .listRemoveInLoop: Info(code: "list-remove-in-loop", title: "Collection modified while it is iterated", group: .probableBugs, severity: .warning, summary: "Reports remove() or add() on the list a loop is iterating over, which throws or skips elements."),
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

    /// Rules that are stylistic or fire on most real code start switched off; Settings can turn them on.
    public var isEnabledByDefault: Bool { !Self.disabledByDefault.contains(self) }

    private static let disabledByDefault: Set<JavaInspectionRule> = [
        .publicField, .synchronizationOnThis, .finalMethodInFinalClass, .protectedMemberInFinalClass,
        .declarationUsesConcreteClass, .classMayBeInterface,
    ]

    /// The rules a new service or fresh preferences run with.
    public static var enabledByDefault: Set<JavaInspectionRule> { Set(allCases.filter(\.isEnabledByDefault)) }

    public init?(code: String) {
        guard let rule = Self.byCode[code] else { return nil }
        self = rule
    }
}

/// A rule with a number the user can tune (the largest acceptable complexity, nesting depth, …).
public struct JavaInspectionLimit: Sendable, Equatable {
    public let label: String
    public let defaultValue: Int
    public let range: ClosedRange<Int>
    public let step: Int
}

extension JavaInspectionRule {
    /// The threshold Settings offers for this rule; nil for rules without one.
    public var limit: JavaInspectionLimit? {
        switch self {
        case .cyclomaticComplexity: JavaInspectionLimit(label: "Maximum complexity", defaultValue: 10, range: 2...100, step: 1)
        case .nestingDepth: JavaInspectionLimit(label: "Maximum nesting depth", defaultValue: 5, range: 2...20, step: 1)
        case .parameterCount: JavaInspectionLimit(label: "Maximum parameters", defaultValue: 7, range: 2...30, step: 1)
        case .methodLength: JavaInspectionLimit(label: "Maximum lines", defaultValue: 100, range: 3...2000, step: 10)
        case .classLength: JavaInspectionLimit(label: "Maximum lines", defaultValue: 1500, range: 3...20000, step: 100)
        default: nil
        }
    }
}

/// The user's values for the rules that have a ``JavaInspectionRule/limit``; a rule not listed uses its default.
public struct JavaInspectionThresholds: Sendable, Equatable {
    public var values: [JavaInspectionRule: Int]

    public init(_ values: [JavaInspectionRule: Int] = [:]) { self.values = values }

    public static let standard = JavaInspectionThresholds()

    /// The value for `rule`, kept inside its range.
    public func value(for rule: JavaInspectionRule) -> Int {
        guard let limit = rule.limit else { return 0 }
        return min(max(values[rule] ?? limit.defaultValue, limit.range.lowerBound), limit.range.upperBound)
    }
}

/// Settings for the project-wide rules (`unused-declaration`, `declaration-access-can-be-weaker`,
/// `method-can-be-void`, `parameter-always-same-value`).
public struct JavaProjectInspectionOptions: Sendable, Equatable {
    /// Public and protected members are API that code outside the project may use, so they are
    /// never reported. Turn off for an application, where nothing outside calls them.
    public var treatsPublicApiAsUsed: Bool

    public init(treatsPublicApiAsUsed: Bool = true) { self.treatsPublicApiAsUsed = treatsPublicApiAsUsed }

    public static let standard = JavaProjectInspectionOptions()
}
