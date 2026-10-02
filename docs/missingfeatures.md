1. Syntactic or near-syntactic (same machinery as now)

These need only the tree and the declared-type lookup we already have.

Probable bugs
- assert with side effects, and constant condition in assert
- Non-short-circuit boolean (& / | between comparisons)
- Comparable implemented but equals() not overridden
- Non-final field used in equals(), hashCode() or compareTo()
- Iterator.hasNext() that calls next()
- Duplicated delimiters in StringTokenizer
- Mismatched case (s.toLowerCase().contains("ABC"))
- Missing whitespace across a string-concatenation line break
- Unsafe Class.newInstance()
- Infinite recursion (the simple unconditional form)

Error handling and code maturity
- Empty catch, catch of Throwable/Exception, unused catch parameter
- return or throw in finally, empty finally
- printStackTrace(), System.out/System.err, System.gc()
- TODO comments

Control flow
- Fallthrough in switch and missing default
- if (c) return true; else return false; (redundant if)
- c ? true : false
- Unnecessary else after return
- Identical if branches
- Duplicate switch branches
- Nested ternary

Code style and numeric
- Redundant field initialisation (int x = 0)
- C-style array declaration
- Missing braces
- Multiple variables in one declaration
- x == true
- Constant on the left of a comparison
- Lowercase l long suffix and octal literals
- x * 1 and x + 0
- new Integer(...) → valueOf
- new int[0]

Class structure and naming
- Naming conventions (class, method, field, constant, local, parameter, type parameter). These are the most visible to users.
- Utility class with a public constructor
- Public field
- Missing serialVersionUID
- clone() without Cloneable
- finalize() declared
- final method in final class, protected member in final class

Others
- Overridable method called in a constructor
- Redundant local variable (int x = f(); return x;)
- Redundant String operations (s.toString(), new String(s), substring(0))
- Synchronizing on a String literal or this
- wait() outside a loop
- Declaration uses concrete class (ArrayList<T> x → List<T>)

2. Needs types through the index (the typed path from last round

- Redundant type cast and redundant type arguments
- size() == 0 → isEmpty()
- Result of method call ignored (for a known list such as String
- Anonymous class can be a lambda (needs the functional-interface check)
- Sorted collection with non-comparable elements
- Suspicious Collection.toArray() and List.remove() in a loop
- Static method or field referenced via a subclass
- Deprecated API usage
- Class may be an interface

3. Needs local flow within one method (moderate new work)

- Mismatched query and update of a collection or StringBuilder
- for loop can be a foreach, and try/finally can be try-with-resources (pattern-matching on shape)
- Local variable can be final
- Unused private members. This is feasible per file, since private members can only be used inside it.
- Unused assignment (flow-lite)

4. Needs infrastructure we don't have

- Data-flow engine: nullability, constant conditions, unreachablhout a check, resource not closed. Almost all of the high-valueProbable-bugs data-flow inspections are here.
- Project-wide usage index: unused declaration, declaration accean be void, method parameter always has the same value.
- Threshold settings: class and method metrics (cyclomatic complexity, nesting depth, parameter count). Easy to detect but they need per-rule numbers in
  Settings.
- Javadoc parsing: missing or invalid @param and @return.
