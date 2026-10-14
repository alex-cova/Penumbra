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
    case threading
    case security
    case testFrameworks
    case migration
    case serialization

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
        case .threading: return "Threading issues"
        case .security: return "Security"
        case .testFrameworks: return "Test frameworks"
        case .migration: return "Java language level migration aids"
        case .serialization: return "Serialization issues"
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
    case unusedLocalVariable
    case fieldCanBeFinal
    case optionalGetWithoutCheck
    case lambdaCanBeMethodReference
    case lambdaBodyCanBeExpression
    case literalEqualsReversed
    case redundantFieldInitializer
    case unnecessarySuperCall
    case redundantInterfaceModifier
    case switchFallThrough
    case duplicateCondition
    case threadRunCall
    case stringLengthZeroCheck
    case formatArgumentCount
    case bigDecimalEquals
    case splitRegexSpecialChar
    case volatileNonAtomicUpdate
    case exceptionCauseLost
    case waitNotifyOutsideSynchronized
    case floatingPointEquality
    case shiftOutOfRange
    case assignmentAsCondition
    case staticNonThreadSafeFormat
    case patternCompileInLoop
    case doubleCheckedLocking
    case weakCryptographicAlgorithm
    case sqlStringConcatenation
    case hardcodedCredential
    case runtimeExecConcatenation
    case assertEqualsArgumentOrder
    case instanceOfPattern
    case enhancedSwitch
    case textBlock
    case localVariableTypeCanBeVar
    case collectionsEmptyFactory
    case stringIsBlank
    case optionalIsEmpty
    case streamToList
    case sequencedCollectionAccess
    case stringFormatted
    case mapGetOrDefault
    case unnecessarySemicolon
    case unnecessaryToString
    case stringIndexOfContains
    case manualArrayCopy
    case arraysFillLoop
    case collectionsSortToListSort
    case deprecatedTagWithoutAnnotation
    case innerClassMayBeStatic
    case switchEnumMissingCases
    case appendConcatenation
    case lowercaseLongLiteral
    case emptySynchronizedBlock
    case sleepWhileHoldingLock
    case unusedParameter
    case methodMayBeStatic
    case fieldMayBeStatic
    case rawTypeUsage
    case uncheckedCast
    case equalsIncompatibleTypes
    case integerOverflowInLongAssignment
    case nonSerializableField
    case deprecatedConstructorUsage
    case deprecatedFieldUsage
    case suspiciousCollectionArgument
    case fieldHidesSuperclassField
    case packageDirectoryMismatch
    case notifyInsteadOfNotifyAll
    case unsafeThreadMethod
    case volatileArrayField
    case cloneWithoutSuperCall
    case equalsWithoutTypeCheck
    case toStringReturnsNull
    case systemExitCall
    case octalLiteral
    case parameterHidesField
    case staticFieldWrittenFromInstance

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
        .nullDereference: Info(code: "null-dereference", title: "Null pointer dereference", group: .probableBugs, severity: .error, summary: "Reports a local that is certainly null where a method is called on it or a member is read."),
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
        .unusedLocalVariable: Info(code: "unused-local-variable", title: "Unused local variable", group: .declarationRedundancy, severity: .warning, summary: "Reports a local variable that is declared but never read or written again."),
        .fieldCanBeFinal: Info(code: "field-can-be-final", title: "Field may be 'final'", group: .declarationRedundancy, severity: .weakWarning, summary: "Reports a private field that has an initializer and is never assigned anywhere else in the file."),
        .optionalGetWithoutCheck: Info(code: "optional-get-without-check", title: "'Optional.get()' without 'isPresent()'", group: .probableBugs, severity: .warning, summary: "Reports get() on an Optional variable that is never tested with isPresent() or isEmpty(); get() throws NoSuchElementException on an empty Optional."),
        .lambdaCanBeMethodReference: Info(code: "lambda-can-be-method-reference", title: "Lambda can be replaced with method reference", group: .verboseCode, severity: .weakWarning, summary: "Reports a lambda that only passes its parameters on to a method or constructor, as in x -> Foo.bar(x) or () -> new Foo()."),
        .lambdaBodyCanBeExpression: Info(code: "lambda-body-can-be-expression", title: "Statement lambda can be replaced with expression lambda", group: .verboseCode, severity: .weakWarning, summary: "Reports a lambda whose block body is a single return or expression statement."),
        .literalEqualsReversed: Info(code: "literal-equals-reversed", title: "'equals()' called on a variable with a literal argument", group: .probableBugs, severity: .weakWarning, summary: "Reports s.equals(\"literal\") on a String variable; \"literal\".equals(s) cannot throw a NullPointerException."),
        .redundantFieldInitializer: Info(code: "redundant-field-initializer", title: "Redundant field initializer", group: .verboseCode, severity: .weakWarning, summary: "Reports a non-final field initialized to the value it has anyway: 0, false, '\\u0000' or null."),
        .unnecessarySuperCall: Info(code: "unnecessary-super-constructor-call", title: "Unnecessary call to 'super()'", group: .verboseCode, severity: .weakWarning, summary: "Reports a super() call with no arguments as the first statement of a constructor; the compiler adds it."),
        .redundantInterfaceModifier: Info(code: "redundant-interface-modifier", title: "Redundant modifier in an interface", group: .verboseCode, severity: .weakWarning, summary: "Reports public or abstract on an interface method, public static final on an interface field, and public static on a nested type, which an interface already implies."),
        .switchFallThrough: Info(code: "switch-fall-through", title: "Fall-through in 'switch' statement", group: .probableBugs, severity: .warning, summary: "Reports a switch case group that runs into the next one because it does not end with break, return, throw or continue. A comment saying 'fall through' silences it."),
        .duplicateCondition: Info(code: "duplicate-condition", title: "Duplicate condition in 'if' chain", group: .probableBugs, severity: .warning, summary: "Reports an else-if whose condition is the same as an earlier condition of the chain, so its branch can never run."),
        .threadRunCall: Info(code: "thread-run-call", title: "Call to 'Thread.run()'", group: .probableBugs, severity: .warning, summary: "Reports run() called on a Thread, which runs the body in the current thread; start() runs it in a new one."),
        .stringLengthZeroCheck: Info(code: "string-length-zero-check", title: "'String.length()' compared with zero", group: .verboseCode, severity: .weakWarning, summary: "Reports s.length() == 0 and its variants where s.isEmpty() says the same."),
        .formatArgumentCount: Info(code: "format-argument-count", title: "Format string and arguments do not match", group: .probableBugs, severity: .warning, summary: "Reports String.format, printf or formatted with a literal format string whose number of conversions differs from the number of arguments."),
        .bigDecimalEquals: Info(code: "bigdecimal-equals", title: "'equals()' called on a BigDecimal", group: .probableBugs, severity: .warning, summary: "Reports BigDecimal.equals(), which compares the scale as well: 1.0 is not equal to 1.00. Use compareTo() == 0."),
        .splitRegexSpecialChar: Info(code: "split-regex-special-char", title: "Regex metacharacter passed to 'split()' or 'replaceAll()'", group: .probableBugs, severity: .warning, summary: "Reports split(\".\"), split(\"|\") and similar: the argument is a regular expression, so the character is not matched literally."),
        .volatileNonAtomicUpdate: Info(code: "volatile-non-atomic-update", title: "Non-atomic update of a volatile field", group: .threading, severity: .warning, summary: "Reports ++, -- and compound assignment on a volatile field outside synchronized code: the read and the write are separate steps, so concurrent updates are lost."),
        .exceptionCauseLost: Info(code: "exception-cause-lost", title: "Caught exception is not passed as the cause", group: .errorHandling, severity: .warning, summary: "Reports a throw of a new exception inside a catch block that never uses the caught exception, so the original stack trace is lost."),
        .waitNotifyOutsideSynchronized: Info(code: "wait-notify-outside-synchronized", title: "'wait()' or 'notify()' outside synchronized code", group: .threading, severity: .warning, summary: "Reports wait(), notify() and notifyAll() called without holding the monitor of their receiver; they throw IllegalMonitorStateException."),
        .floatingPointEquality: Info(code: "floating-point-equality", title: "Floating-point equality comparison", group: .probableBugs, severity: .weakWarning, summary: "Reports == and != on float or double values; rounding makes exact equality unreliable. Comparisons with zero, NaN and infinities are not reported."),
        .shiftOutOfRange: Info(code: "shift-out-of-range", title: "Shift distance out of range", group: .probableBugs, severity: .warning, summary: "Reports a shift by a constant that is negative or not smaller than the width of the type (32 for int, 64 for long); only the low bits of the distance are used."),
        .assignmentAsCondition: Info(code: "assignment-as-condition", title: "Assignment used as a condition", group: .probableBugs, severity: .warning, summary: "Reports if (flag = value): an assignment where a comparison was probably meant."),
        .staticNonThreadSafeFormat: Info(code: "static-non-thread-safe-format", title: "Static field of a non-thread-safe format class", group: .threading, severity: .warning, summary: "Reports a static SimpleDateFormat, DateFormat, NumberFormat, DecimalFormat or Calendar, which keep internal state and break when shared between threads."),
        .patternCompileInLoop: Info(code: "pattern-compile-in-loop", title: "'Pattern.compile()' of a constant in a loop", group: .performance, severity: .weakWarning, summary: "Reports Pattern.compile with a literal pattern inside a loop; compile it once into a static field."),
        .doubleCheckedLocking: Info(code: "double-checked-locking", title: "Double-checked locking", group: .threading, severity: .warning, summary: "Reports lazy initialization that tests a field, locks, and tests again when the field is not volatile; another thread can see a partly constructed object."),
        .weakCryptographicAlgorithm: Info(code: "weak-cryptographic-algorithm", title: "Weak cryptographic algorithm", group: .security, severity: .warning, summary: "Reports MessageDigest MD2, MD4, MD5 and SHA-1, and Cipher transformations that use DES, 3DES, RC2, RC4 or ECB mode (AES without a mode is ECB)."),
        .sqlStringConcatenation: Info(code: "sql-string-concatenation", title: "SQL built by string concatenation", group: .security, severity: .warning, summary: "Reports a query passed to executeQuery, prepareStatement and similar that is concatenated from a literal and a variable; use query parameters to prevent SQL injection."),
        .hardcodedCredential: Info(code: "hardcoded-credential", title: "Hard-coded credential", group: .security, severity: .warning, summary: "Reports a variable or field named password, secret, apiKey or similar that is initialized with a string literal."),
        .runtimeExecConcatenation: Info(code: "runtime-exec-concatenation", title: "Command built by string concatenation", group: .security, severity: .warning, summary: "Reports Runtime.exec with a command concatenated from a literal and a variable, which allows command injection."),
        .assertEqualsArgumentOrder: Info(code: "assert-equals-argument-order", title: "JUnit assertion arguments in the wrong order", group: .testFrameworks, severity: .weakWarning, summary: "Reports assertEquals(actual, expected-literal): JUnit takes the expected value first, so a failure message would name the wrong value."),
        .instanceOfPattern: Info(code: "instanceof-pattern", title: "'instanceof' followed by a cast can use a pattern", group: .migration, severity: .weakWarning, summary: "Reports if (x instanceof Foo) { Foo f = (Foo) x; ... } where a pattern variable (x instanceof Foo f) does the same. Needs Java 16."),
        .enhancedSwitch: Info(code: "enhanced-switch", title: "Statement 'switch' can be replaced with enhanced 'switch'", group: .migration, severity: .info, summary: "Reports an old-style switch whose groups all end in break, return or throw; the arrow form cannot fall through by mistake. Needs Java 14."),
        .textBlock: Info(code: "text-block", title: "String concatenation can be replaced with a text block", group: .migration, severity: .weakWarning, summary: "Reports several string literals concatenated line by line with \\n; a text block says it without the escapes. Needs Java 15."),
        .localVariableTypeCanBeVar: Info(code: "local-variable-type-can-be-var", title: "Local variable type can be omitted", group: .migration, severity: .info, summary: "Reports a local whose declared type repeats the initializer's, as in Foo f = new Foo() or String s = \"x\"; var says it once. Needs Java 10."),
        .collectionsEmptyFactory: Info(code: "collections-empty-factory", title: "'Collections.emptyList()' can be replaced with 'List.of()'", group: .migration, severity: .weakWarning, summary: "Reports Collections.emptyList(), emptySet() and emptyMap(), which List.of(), Set.of() and Map.of() replace. The new collections throw NullPointerException from contains(null), so it is off by default. Needs Java 9."),
        .stringIsBlank: Info(code: "string-is-blank", title: "'trim().isEmpty()' can be replaced with 'isBlank()'", group: .migration, severity: .weakWarning, summary: "Reports s.trim().isEmpty() and s.strip().isEmpty() on a String, which s.isBlank() says directly. Needs Java 11."),
        .optionalIsEmpty: Info(code: "optional-is-empty", title: "'!optional.isPresent()' can be replaced with 'isEmpty()'", group: .migration, severity: .weakWarning, summary: "Reports a negated Optional.isPresent(); Optional.isEmpty() says it directly. Needs Java 11."),
        .streamToList: Info(code: "stream-to-list", title: "'collect(Collectors.toList())' can be replaced with 'toList()'", group: .migration, severity: .weakWarning, summary: "Reports collect(Collectors.toList()), which Stream.toList() replaces. The result of toList() cannot be modified, so check what the list is used for. Needs Java 16."),
        .sequencedCollectionAccess: Info(code: "sequenced-collection-access", title: "'get(0)' / 'get(size() - 1)' can use 'getFirst()' / 'getLast()'", group: .migration, severity: .info, summary: "Reports list.get(0) and list.get(list.size() - 1) on a List, ArrayList or LinkedList. An empty list throws NoSuchElementException instead of IndexOutOfBoundsException. Needs Java 21."),
        .stringFormatted: Info(code: "string-formatted", title: "'String.format()' can be replaced with 'formatted()'", group: .migration, severity: .info, summary: "Reports String.format with a literal format string, which \"...\".formatted(args) replaces. Needs Java 15."),
        .mapGetOrDefault: Info(code: "map-get-or-default", title: "Conditional can be replaced with 'getOrDefault()'", group: .migration, severity: .weakWarning, summary: "Reports m.containsKey(k) ? m.get(k) : d, which m.getOrDefault(k, d) says directly. Needs Java 8."),
        .unnecessarySemicolon: Info(code: "unnecessary-semicolon", title: "Unnecessary semicolon", group: .verboseCode, severity: .weakWarning, summary: "Reports a semicolon between class members or after a type declaration that ends nothing."),
        .unnecessaryToString: Info(code: "unnecessary-to-string", title: "Unnecessary 'toString()' call", group: .verboseCode, severity: .weakWarning, summary: "Reports x.toString() as an operand of a string concatenation, which converts x anyway (and prints null instead of throwing)."),
        .stringIndexOfContains: Info(code: "string-index-of-contains", title: "'indexOf()' comparison can be replaced with 'contains()'", group: .verboseCode, severity: .weakWarning, summary: "Reports s.indexOf(str) != -1, >= 0 and their negations on a String, which s.contains(str) says directly."),
        .manualArrayCopy: Info(code: "manual-array-copy", title: "Manual array copy", group: .performance, severity: .weakWarning, summary: "Reports a loop that copies one array element by element; System.arraycopy() does it faster."),
        .arraysFillLoop: Info(code: "arrays-fill-loop", title: "Loop can be replaced with 'Arrays.fill()'", group: .verboseCode, severity: .weakWarning, summary: "Reports a loop that stores the same value in every element of an array."),
        .collectionsSortToListSort: Info(code: "collections-sort-to-list-sort", title: "'Collections.sort()' can be replaced with 'List.sort()'", group: .migration, severity: .info, summary: "Reports Collections.sort(list) and Collections.sort(list, comparator) on a declared List. Needs Java 8."),
        .deprecatedTagWithoutAnnotation: Info(code: "deprecated-tag-without-annotation", title: "'@deprecated' tag without '@Deprecated' annotation", group: .codeMaturity, severity: .warning, summary: "Reports a declaration whose Javadoc has @deprecated but that is not annotated @Deprecated, so the compiler does not warn its users."),
        .innerClassMayBeStatic: Info(code: "inner-class-may-be-static", title: "Inner class may be 'static'", group: .classStructure, severity: .weakWarning, summary: "Reports a non-static member class that uses nothing of its enclosing instance; static saves the hidden reference and avoids leaking the outer object."),
        .switchEnumMissingCases: Info(code: "switch-enum-missing-cases", title: "'switch' over an enum misses constants", group: .probableBugs, severity: .warning, summary: "Reports a switch statement on an enum declared in the same file that has no default and does not name every constant."),
        .appendConcatenation: Info(code: "append-concatenation", title: "String concatenation as argument to 'append()'", group: .performance, severity: .weakWarning, summary: "Reports sb.append(\"a\" + b), which builds a temporary String; append the parts one by one."),
        .lowercaseLongLiteral: Info(code: "lowercase-long-literal", title: "Long literal with lowercase 'l'", group: .namingConventions, severity: .weakWarning, summary: "Reports 100l, whose suffix is easily read as the digit 1; use 100L."),
        .emptySynchronizedBlock: Info(code: "empty-synchronized-block", title: "Empty 'synchronized' block", group: .threading, severity: .weakWarning, summary: "Reports a synchronized block with no statements, which only waits for the lock and is usually a mistake."),
        .sleepWhileHoldingLock: Info(code: "sleep-while-holding-lock", title: "'Thread.sleep()' while holding a lock", group: .threading, severity: .warning, summary: "Reports Thread.sleep() inside a synchronized block or method, which keeps every other thread out for the whole sleep."),
        .unusedParameter: Info(code: "unused-parameter", title: "Unused parameter of a private method", group: .declarationRedundancy, severity: .weakWarning, summary: "Reports a parameter of a private method that its body never reads."),
        .methodMayBeStatic: Info(code: "method-may-be-static", title: "Method may be 'static'", group: .declarationRedundancy, severity: .weakWarning, summary: "Reports a private method that uses no instance state: no this, no instance fields or methods, no type parameters of the class."),
        .fieldMayBeStatic: Info(code: "field-may-be-static", title: "Field may be 'static'", group: .declarationRedundancy, severity: .weakWarning, summary: "Reports a final instance field initialized with a literal, which every instance holds a copy of."),
        .rawTypeUsage: Info(code: "raw-type-usage", title: "Raw use of a parameterized class", group: .compilerIssues, severity: .weakWarning, summary: "Reports List, Map and other generic classes used without type arguments, which turns off generic type checking."),
        .uncheckedCast: Info(code: "unchecked-cast", title: "Unchecked cast", group: .compilerIssues, severity: .weakWarning, summary: "Reports a cast to a parameterized type such as (List<String>) o, which the runtime cannot check."),
        .equalsIncompatibleTypes: Info(code: "equals-incompatible-types", title: "'equals()' between incompatible types", group: .probableBugs, severity: .warning, summary: "Reports equals() or Objects.equals() on two values whose declared types are different wrapper types or String and a number; the result is always false."),
        .integerOverflowInLongAssignment: Info(code: "integer-overflow-in-long-assignment", title: "Integer arithmetic widened to 'long' after overflow", group: .probableBugs, severity: .warning, summary: "Reports long x = a * b (and a << n) where the operands are int: the product is computed in int and can overflow before it is widened."),
        .nonSerializableField: Info(code: "non-serializable-field", title: "Non-serializable field in a Serializable class", group: .serialization, severity: .warning, summary: "Reports a non-transient instance field of a type that is known not to be Serializable, in a class that implements Serializable."),
        .deprecatedConstructorUsage: Info(code: "deprecated-constructor-usage", title: "Use of a deprecated constructor", group: .codeMaturity, severity: .warning, summary: "Reports new Foo(...) where every constructor that fits the arguments is marked deprecated."),
        .deprecatedFieldUsage: Info(code: "deprecated-field-usage", title: "Use of a deprecated field", group: .codeMaturity, severity: .warning, summary: "Reports a read or write of a field the library marks deprecated."),
        .suspiciousCollectionArgument: Info(code: "suspicious-collection-argument", title: "Argument type does not match the collection's element type", group: .probableBugs, severity: .warning, summary: "Reports contains, indexOf, remove, get and containsKey called with a value of a different wrapper type than the collection holds, such as List<String>.contains(1); the call is always false."),
        .fieldHidesSuperclassField: Info(code: "field-hides-superclass-field", title: "Field hides a field of a superclass", group: .classStructure, severity: .warning, summary: "Reports a field with the same name as an accessible field of a superclass; code that sees one cannot see the other."),
        .packageDirectoryMismatch: Info(code: "package-directory-mismatch", title: "Package name does not match the directory", group: .compilerIssues, severity: .warning, summary: "Reports a package declaration that the file's directory does not end with."),
        .notifyInsteadOfNotifyAll: Info(code: "notify-instead-of-notify-all", title: "'notify()' instead of 'notifyAll()'", group: .threading, severity: .weakWarning, summary: "Reports notify(), which wakes one arbitrary waiter; with several conditions on one monitor the wrong thread may wake."),
        .unsafeThreadMethod: Info(code: "unsafe-thread-method", title: "Call to an unsafe 'Thread' method", group: .threading, severity: .warning, summary: "Reports Thread.stop(), suspend(), resume() and destroy(), which are deprecated because they leave locks and state inconsistent."),
        .volatileArrayField: Info(code: "volatile-array-field", title: "Volatile array field", group: .threading, severity: .warning, summary: "Reports a volatile array: only the reference is volatile, not the elements."),
        .cloneWithoutSuperCall: Info(code: "clone-without-super-call", title: "'clone()' does not call 'super.clone()'", group: .classStructure, severity: .warning, summary: "Reports a clone() that never calls super.clone(), so a subclass's clone returns the wrong class."),
        .equalsWithoutTypeCheck: Info(code: "equals-without-type-check", title: "'equals()' casts its parameter without checking its type", group: .probableBugs, severity: .warning, summary: "Reports an equals(Object) that casts the argument with no instanceof or getClass() test; it throws ClassCastException for another type."),
        .toStringReturnsNull: Info(code: "to-string-returns-null", title: "'toString()' returns null", group: .probableBugs, severity: .warning, summary: "Reports return null in toString(); string concatenation and loggers expect a String."),
        .systemExitCall: Info(code: "system-exit-call", title: "Call to 'System.exit()' or 'Runtime.halt()'", group: .codeMaturity, severity: .weakWarning, summary: "Reports a call that shuts the whole JVM down; it makes the code hard to test and to embed."),
        .octalLiteral: Info(code: "octal-literal", title: "Octal integer literal", group: .probableBugs, severity: .weakWarning, summary: "Reports 010 and similar, which equals 8 and is easily read as decimal."),
        .parameterHidesField: Info(code: "parameter-hides-field", title: "Parameter hides a field", group: .classStructure, severity: .weakWarning, summary: "Reports a method parameter named like a field of the same class (constructors and setters are skipped)."),
        .staticFieldWrittenFromInstance: Info(code: "static-field-written-from-instance", title: "Static field written from an instance method", group: .classStructure, severity: .weakWarning, summary: "Reports an assignment to a non-final static field inside an instance method, which every instance shares."),
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
        // Style preferences: the JDK's own sources trip them hundreds of times.
        .literalEqualsReversed, .redundantFieldInitializer,
        // Name-based guess; on by choice.
        .hardcodedCredential,
        // Exact comparison is deliberate in numeric code (the JDK's own math trips it 37 times).
        .floatingPointEquality,
        // Style and caution: `var` is a taste, and `toList()` returns an unmodifiable list.
        .localVariableTypeCanBeVar, .streamToList,
        // `List.of().contains(null)` throws; `Collections.emptyList().contains(null)` does not.
        .collectionsEmptyFactory,
        // Style and noise: raw types and unchecked casts are legitimate in legacy code, and a private
        // method that could be static is a taste.
        .rawTypeUsage, .uncheckedCast, .methodMayBeStatic,
        // Style preferences and loud checks: a call to notify() is often right, System.exit belongs to
        // main methods, octal literals are rare and deliberate, and hiding a field is how constructors work.
        .notifyInsteadOfNotifyAll, .systemExitCall, .octalLiteral, .parameterHidesField, .staticFieldWrittenFromInstance,
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
