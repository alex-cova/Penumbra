# Java semantic model (`Sources/JavaIntelligence/Semantics`)

Loaded when working under `Sources/JavaIntelligence/Semantics`. The symbol/scope/type
foundation (Phase 3 of `docs/JAVA_PARITY.md`'s plan): names every declaration, builds JLS 6.3
scopes once per parse, and answers type operations in one place. No dependency on `Penumbra`;
Umbra reaches it through providers, never directly.

- **Symbols** (`Model/JavaSymbol.swift`, `References/JavaSymbolID.swift`). `JavaSymbol` names
  every declaration kind — local, parameter, field, method, constructor, type, local type,
  type parameter, package, label — each carrying its declaration site (file plus the UTF-8 byte
  range of the declaring name) and, where a stub model exists, its stub. `id` follows
  `JavaSymbolID`: declared signatures, never substituted types, so the same method yields the
  same ID however it was reached. Locals and parameters share the `.local` site identity;
  type parameters, packages and labels have no ID yet. `.localType` covers classes declared in
  a body and anonymous class bodies (empty name, sited at the `new` expression), which have no
  qualified name, so usages and rename name them by site. Tests: `JavaSymbolTests`.
- **Scope tree** (`Model/JavaScopeTree.swift`). The lexical scopes of one parse, built once and
  memoized on the parse (`JavaSyntaxTree.scopeTree(for:)`, via `JavaScopeTreeCache`) instead of
  re-walked per query like `JavaLocalScope.locals(in:atByteOffset:)`. Each declaration carries
  the byte range it is visible in, so `locals(atByteOffset:)`, `symbol(named:atByteOffset:)`
  and `scopeChain(atByteOffset:)` are range checks, not tree walks. Covers file, types (member
  types qualify as `Outer.Inner`; body-local types identify by site), methods/constructors/
  initializers, blocks, `for`/enhanced-`for` (including `var` iteration variables with
  `initializerText`), try-with-resources (resources scope over the body, catches and finally,
  JLS 6.3), catch (multi-catch records every type in `alternativeTypes`; the primary stays the
  first until the type system computes the lub), lambdas (inferred parameters carry their
  `JavaLambdaOrigin`), one scope per `switch` block with rules beneath it, pattern bindings
  with polarity (`&&` left-to-right, `||` under negation, `!` flips; bindings also visible
  inside their own right operands in any statement position) and flow-out past guard returns,
  record patterns (components typed from the pattern itself), local types, labels, and member
  recovery inside `ERROR` regions. Deliberate JLS-closer deltas from `JavaLocalScope`, pinned
  by tests: a local is visible in its own initializer, switch groups share one scope.
  Out of v1, documented at each site: qualifier resolution, single-static-import names,
  do-while pattern flow, `var` resources naming an existing variable, operand visibility under
  an explicit `!`. Cost: ~6 ms build on a 2k-line file in Release
  (`swift run -c release PerfHarness java-scope-tree synthetic --lines 2000`, exit ≤ 50 ms);
  the debug unit test only guards against pathological blowups (1 s). Tests:
  `JavaScopeTreeTests` (parity against `JavaLocalScope` on shared cases, plus every delta).
- **Type system** (`Model/JavaTypeSystem.swift`). The one place for operations over
  `JavaTypeRef`: `substitute` (absorbed from `JavaMemberLookup`, which delegates),
  `erasure` (JLS 4.6; unresolvable variables go to `Object`, unresolved names stay
  unresolved), `erasedName` (the `method:String(int)` identity keys), `lub` (JLS 4.10.4,
  v1: erased — one erasure returns the original reference with arguments, otherwise the most
  specific common supertype through the index, raw; `nil` when names are unattributed or
  hierarchies stay open), `effectiveCatchType` (the lub, else the first alternative, else
  `Throwable`), and `inferredVarType` (the `var` seam `resolvingVarLocals` assigns through;
  Phase 4 attribution plugs denotability and richer inference in there). `asSuper` stays on
  `JavaMemberLookup.asSupertype` until attribution; the lub reaches it through the public
  query. No `JavaType` nominal yet — that needs the attributor. Tests: `JavaTypeSystemTests`
  (substitution, erasure, lub over a shard-built stub hierarchy, the var seam).
- **Incumbents the model is absorbing.** `JavaLocalScope` still answers per-query locals for
  live buffers (the tree is its tested successor for parsed files); `JavaExpressionTyper`
  keeps its public API (`receiverInfo`, `typeOfExpression`, `resolvingVarLocals`) and will
  become a façade over the attributor; `JavaMemberLookup` (generic-aware members,
  `asSupertype`, `supertypeClosure`) and `JavaTypeResolver` (simple names against
  `JavaResolutionContext`: package, imports, enclosing types, type parameters and bounds)
  stay the resolution workhorses. `JavaReceiverScanner` finds the pre-dot expression
  textually (reparsing a dangling `.` collapses too much into `ERROR`); `JavaStaticImports`
  names single and on-demand static-import members.
