# Missing IDE Features for Umbra, on the IntelliJ Keymap

Origin: a JetBrains Fleet keymap cheat sheet (`~/Desktop/keymap.pdf`) was compared against Umbra. Umbra will **not** get a Fleet keymap. The features the sheet lists that Umbra lacks are still worth building, and each one is bound in the existing `Keymap.intelliJ` preset using IntelliJ IDEA's macOS key for that action. Where IntelliJ has no default key, the feature gets a menu item and Find Action only.

## Ground rules

- **App Store safety** (CLAUDE.md). Nothing in `Sources/Penumbra` or `Sources/EditorIntelligence` spawns processes or makes network calls. Git, debugger and AI work stays in `Example/Umbra` or `Packages/GitIntelligence`, and runs only on an explicit user action.
- **Performance rules** (`docs/PERFORMANCE_RULES.md`). New editor actions are bounded by the edit or the visible rows, never by document size. Use `lineID(atRow:)` / `lineInfo(atRow:)` / `location(ofRow:)`, not `line(atRow:)` handles. Bracket and fold lookups use a tree-sitter node or a bounded byte scan.
- **Editor-agnostic core.** `EditorIntelligence` stays free of `Penumbra` types. New navigation kinds go through `NavigationContext.kind`.
- **Each phase ships with tests** (`Tests/PenumbraTests/<Subject>Tests.swift`, one class per file) and a line in the CLAUDE.md feature list.
- IntelliJ keys below are IntelliJ IDEA's default macOS keymap as I remember it. Confirm each against JetBrains' reference card (Help | Keyboard Shortcuts PDF) when the binding is added.

## Status

| Phase | State | Scope |
|---|---|---|
| 0 | Done | `IDEMenuShortcuts` (`Example/Umbra/IDEMenuShortcuts.swift`) gives every preset-dependent menu item its shortcut per `KeymapPreset`; `UmbraApp.swift` uses it. The IntelliJ column also carries the tool-window keys of 6.3 (⌘1, ⌘6, ⌘9, ⌥F12; ⌘7 unchanged) and Reveal in Explorer on ⌥F1. `Keymap.intelliJ` gained ⇧⌘F (Find in Files) and ⌘F12 (File Structure). `IDEMenuShortcutsTests` checks no two commands share a key, the Sublime/Default columns are unchanged, and menu keys agree with the IntelliJ keymap. Sublime/Default lost the duplicate ⌥⌘E on Reveal Active File (Encapsulate Field keeps it). Full suite: 2531 tests, 0 failures. |
| 1 | Done | 1.1 block comment (`BlockCommentService`, `BlockCommentDelimiters`, ⌥⌘/), 1.2 matching brace (`BracketNavigation`, `goToMatchingBracket`), 1.3 folding commands (landed upstream before this work), 1.4 `unselectLastOccurrence`, 1.5 complete statement (`StatementCompletionService`, ⇧⌘↵), 1.6 IntelliJ line-insert keys (⇧↵, ⌥⌘↵; ⌘↵ unbound), 1.7 `findNext`/`findPrevious`. |
| 2 | Done | 2.1 next/prev problem (`ProblemNavigator`, `goToNextProblem`/`goToPreviousProblem`, F2 / ⇧F2), 2.2 go to type declaration (`NavigationKind.typeDefinition`, `JavaGoToTypeDefinition`, `LSPTypeDefinitionProvider`, ⌃⇧B), 2.3 parameter info (`showParameterInfo`, ⌘P), 2.4 symbol scopes (`goToFileSymbol` ⌘F12 / `goToSymbol` ⌥⌘O, `FileSymbolsPaletteProvider`). |
| 3 | Partly done | Done: 3.1 step into/out, 3.2 pause, 3.5 Run menu and IntelliJ keys, plus the adapter fixes below that debugging needed before any of it could work. Verified against a real JVM by `JavaDebugAdapterTests`; the Swift session, panel, stop-line reveal and menu were built but not run in the app. Open: 3.3 evaluate, 3.4 run in context. |
| 4 | Partly done | Done: 4.2 file history, 4.3 revert, 4.4 pull/push keys and a Git menu; the git side is tested against real repositories, the Umbra UI (panel header, dialogs, menu) was built but not run. Open: 4.1 blame. |
| H | Built, not seen on screen | `play.fill` gutter button per request in `.http` files (`HTTPRequestParser.requestLocations`, `IDEWorkspace.refreshHTTPGutter`). Parser tests pass; the app launches with an `.http` file without crashing, but I could not take a screenshot here, so the icons have not been looked at. |
| 5 | Done (UI not run) | `ProjectReplacePlanner` + `IDEReplaceInFilesGuard`, the drawer's replace row and options, ⇧⌘R in the IntelliJ column. Planner, guard and the write-to-disk path are tested; the drawer and the live-editor path were built but not run in the app. |
| 6 | Done (not run in the app) | 6.1 next/prev tab, 6.2 next/prev split, 6.3 tool-window keys (⌘1/⌘5/⌘6/⌘7/⌘9/⌥F12 and Hide All ⇧⌘F12), 6.4 zoom, 6.5 Clear Terminal, 6.6 Go to Tool Window, 6.7 emoji (checked in code only, no change needed). Differences from the plan below. |
| 7 | Needs a decision | Generate Code with AI |

Phase 0 goes first because every later menu-level action needs it. Phases 1–3 need only Penumbra and JavaIntelligence and can run in parallel.

---

## Key map (IntelliJ preset)

New bindings, all added to `Keymap.intelliJ` (editor-level) or the menu table from phase 0 (app-level).

| Feature | IntelliJ key | Level | Conflict to resolve |
|---|---|---|---|
| Toggle Block Comment | ⌥⌘/ | editor | none |
| Move Caret to Matching Brace | ⌃M | editor | none |
| Collapse / Expand fold at caret | ⌘- / ⌘+ (also ⌘=) | editor | none in IntelliJ; zoom deliberately gets no key (see 6.4) |
| Collapse / Expand All | ⇧⌘- / ⇧⌘+ | editor | none |
| Unselect Last Occurrence | ⌃⇧G | editor | none |
| Complete Current Statement | ⇧⌘↵ | editor | `default_` binds ⇧⌘↵ to Insert Line Above; the IntelliJ preset unbinds that |
| Start New Line | ⇧↵ | editor | action `startNewLine` already exists but is unbound in the preset |
| Start New Line Before Current | ⌥⌘↵ | editor | replaces `default_`'s ⇧⌘↵ binding for `insertLineAbove` |
| Find Next / Previous | ⌘G / ⇧⌘G | editor | none in the IntelliJ preset (Sublime uses ⌘G for Go to Line) |
| Next / Previous Highlighted Error | F2 / ⇧F2 | editor | none |
| Go to Type Declaration | ⌃⇧B | editor | none |
| Parameter Info | ⌘P | editor | Umbra's Go menu hard-codes ⌘P for Go to File (fixed by phase 0) |
| File Structure (symbols in file) | ⌘F12 | editor | none |
| Go to Symbol (workspace) | ⌥⌘O | editor | none |
| Find in Files | ⇧⌘F | editor | missing from the IntelliJ preset today (only Sublime binds it); works only because the menu hard-codes it |
| Replace in Files | ⇧⌘R | menu | Umbra's HTTP "Send Request" is hard-coded to ⇧⌘R today. IntelliJ wins: in the IntelliJ preset ⇧⌘R is Replace in Files and Send Request moves (next row) |
| HTTP Send Request | ⌃↵ (plus the play.fill gutter icon, phase H) | menu | Sublime and Default presets keep ⇧⌘R |
| Step Over / Into / Out | F8 / F7 / ⇧F8 | menu | none |
| Resume | ⌥⌘R | menu | none |
| Toggle Breakpoint | ⌘F8 | menu | none |
| Evaluate / Quick Evaluate | ⌥F8 / ⌥⌘F8 | menu | none |
| Run / Debug in Context | ⌃⇧R / ⌃⇧D | menu | none |
| Stop | ⌘F2 | menu | none |
| Revert (Rollback) | ⌥⌘Z | menu | none |
| Git Push / Update (pull) | ⌘⇧K / ⌘T | menu | none |
| Next / Previous Tab | ⇧⌘] / ⇧⌘[ | menu | none |
| Next / Previous Split | ⌥⇥ / ⌥⇧⇥ | menu | none |
| Tool windows | ⌘1 Explorer, ⌘5 Debug, ⌘6 Problems, ⌘7 Structure, ⌘9 Source Control, ⌥F12 Terminal, ⇧⌘F12 Hide All | menu | ⌘1 to ⌘9 are unbound in Umbra today except ⌘7 |
| Clear Terminal | ⌘K (terminal focused only) | terminal | ⌘K is the chord prefix for ⌘K ⌘D; only while the terminal is first responder |

No IntelliJ default key exists for: Pause, Git Blame (Annotate), File History, Zoom, Go to Tool, and Generate Code with AI. Those are reachable from menus, Find Action and Search Everywhere.

Dropped, because they only exist in Fleet: the Goto Popup, Focus First/Second Split (replaced by next/previous split), and Fleet's ⌘1/2/3 panel scheme (replaced by IntelliJ's numbered tool windows).

Observation, out of scope: the IntelliJ preset binds Find Usages to ⌘⌥⇧B, while IntelliJ's own key is ⌥F7. Worth a separate look.

---

## Phase 0: menu shortcuts follow the preset

`UmbraApp.swift` hard-codes `.keyboardShortcut(...)` on menu items with **Sublime** keys (⌘P Go to File, ⌘R Go to Symbol, ⌘L Go to Line, ⇧⌘P palette, ⌘0 sidebar, ⌘B Markdown Preview, ⇧⌘R Send Request, and others). SwiftUI menu shortcuts take the key before `TextInputView` sees it (see the comment on the Undo/Redo group). The result is that, under the IntelliJ preset, ⌘P still opens Go to File and ⇧⌘O still opens Open Folder, even though `Keymap.intelliJ` binds ⇧⌘O to Go to File. The new bindings above would be shadowed the same way.

Plan:

1. Add `IDEMenuShortcuts` in `Example/Umbra`: a table mapping an `IDEMenuCommand` to an optional `KeyboardShortcut`, one column per `KeymapPreset` (`sublime`, `default_`, `intelliJ`). The Sublime and Default columns reproduce today's shortcuts exactly, so nothing changes for those users.
2. Replace the literal `.keyboardShortcut` calls with a modifier that reads the table for `preferences.keymapPreset`, and applies nothing when the preset has no key for that command.
3. Editor-level actions stay in `Keymap`; their menu items call `TextView.perform(_:)`.
4. Fix the existing gaps in `Keymap.intelliJ`: bind ⇧⌘F to `findInFiles`; make the Go menu items (Go to File, Go to Symbol, Go to Line, Command Palette) match the preset's editor keys.

Tests: `KeymapTests` gets an assertion that no two actions in `Keymap.intelliJ` share a stroke, and an `IntelliJKeymapTests` table with one row per binding in the key map above. A menu-table test checks that no two commands in one preset column share a shortcut.

---

## Phase 1: Editor actions (Penumbra)

Each is a new `EditorActionID` with a `builtInTitles` entry (so Find Action lists it), a `case` in `TextInputView.performKeymapAction`, a public `TextView` method, and a line in `Keymap.intelliJ`.

### 1.1 Toggle Block Comment (⌥⌘/)

- `InternalLanguageMode` has `lineCommentPrefix` (`InternalLanguageMode.swift:29`). Add `blockCommentDelimiters: (open: String, close: String)?`, defined in `TreeSitterInternalLanguageMode` beside the line prefix. Java, Swift, JS/TS, CSS, Go, Kotlin, C-family use `/* */`; HTML and XML use `<!-- -->`. Python, YAML and shell return `nil`, and the action does nothing.
- **As built:** a separate `BlockCommentService` (`Sources/Penumbra/TextView/Core/`) rather than an extension of `CommentToggleService`. With a selection it wraps, or unwraps when the selection is exactly a comment or sits inside one. With a caret it wraps the line's non-whitespace content, or unwraps the comment holding the caret. Comments are found by a text scan of ±4096 UTF-16 units, not by tree-sitter nodes, so a `/*` inside a string literal counts as a comment start and injected languages (`<script>` in HTML) use the root language's delimiters. A line already holding a closed comment is not wrapped (it would nest). Delimiters are set on the Java, Swift, Go, Rust, Kotlin, C, C++, SQL, JavaScript, TypeScript and CSS packs (`/* */`) and HTML (`<!-- -->`).
- Original plan: extend `CommentToggleService`. With a selection it wraps, or unwraps when the selection is already exactly enclosed. With a caret it wraps the current line's non-whitespace content, or unwraps when the caret is inside a comment node (`syntaxNode(at:)`); without a tree it scans for the delimiters.
- Multi-caret aware, one undo step, isolated undo grouping like `toggleComment`.
- A selection that contains the closing delimiter makes no edit.

### 1.2 Move Caret to Matching Brace (⌃M)

- `BracketMatchingController` already finds a partner with a bounded scan (`findClosingPair`, `limit:`). Expose `matchingBracketLocation(near:)`, and add `.goToMatchingBracket`. With the caret not next to a bracket, it moves to the enclosing open bracket (IntelliJ behaviour), found through the tree-sitter node when there is one.
- Pressing it again jumps to the other end. Per-caret for multi-caret.

### 1.3 Folding commands (⌘- / ⌘+, ⇧⌘- / ⇧⌘+)

- Folding today is gutter-only (`FoldingController`). Add `foldAtCaret`, `unfoldAtCaret`, `foldAll`, `unfoldAll`. The controller already has a private `expandAll`; make it internal and add the counterparts.
- `foldAtCaret` folds the innermost unfolded region containing the caret, and a second press folds the next enclosing one. `unfoldAtCaret` unfolds the folded region on the caret line.
- `foldAll` folds only regions the provider has produced, hiding heights in one pass through the line manager rather than per row (CLAUDE.md records a per-row handle walk costing ~8 ms per keystroke). Measure with `PerfHarness enter-session synthetic --lines 20000` and 120000, before and after.
- Check how `KeyChord` handles shifted characters: ⌘+ is ⌘⇧= physically, so bind both ⌘= and ⌘+.

### 1.4 Unselect Last Occurrence (⌃⇧G)

- `MultiSelectionController` keeps selections in the order `selectNextOccurrence` added them. Add `removeLastOccurrence()`: drop the most recently added one, make the previous selection primary, and scroll to it. With a single selection it does nothing.
- This is not `undoLastCaretChange`, which also reverts vertical caret clones. Keep them separate. If the controller doesn't track which selections came from occurrence expansion, add an insertion-order array.

### 1.5 Complete Current Statement (⇧⌘↵)

- **As built:** `StatementCompletionService` (`Sources/Penumbra/TextView/Enter/`) is a textual, single-line decision (no tree-sitter, so it works on code that doesn't parse), and `TextInputView.completeStatement()` applies it and then inserts a line break through the normal Enter path, so `{|}` is split and indented by the existing Enter handlers. It skips string and character literals and comments, leaves text blocks alone, and treats a line ending in an operator, comma, `:` or `->`, an annotation, or an opening `{` as unfinished. Methods and constructors are recognised by a declaration pattern (`Type name(...)`, or modifiers plus a name), so `foo(x)` gets `;` and `public void run()` gets a body. Only languages whose `enterBehavior.cStyleIndent` is set (Java) get this; others fall back to Start New Line.
- Original plan: add `.completeStatement` and a `StatementCompletionService` beside `StatementRangeService`. With a tree-sitter tree, find the innermost incomplete statement at the caret and close it, in order:
  1. Append missing `)` / `]` so brackets balance.
  2. For a header that expects a body (`if`, `for`, `while`, `switch`, a method or class declaration without `{`), add ` {`, an indented blank line and `}`, and put the caret in the body.
  3. Otherwise append `;`, only for languages whose `EnterBehavior` says they use one.
  4. Move the caret to the end of the statement, or into the new body.
- Languages without those flags fall back to Start New Line, so the key is never dead.
- One undo step, through `replaceText`.
- Java golden tests first: `foo(bar(` → `foo(bar());`, `if (x` → `if (x) {` / body / `}`.
- Depends on unbinding `default_`'s ⇧⌘↵ (Insert Line Above) in the IntelliJ preset; Insert Line Above moves to ⌥⌘↵.

### 1.6 Start New Line (⇧↵) and Start New Line Before Current (⌥⌘↵)

- The `startNewLine` action and `insertLine(above:)` exist. This is keymap-only: bind ⇧↵ to `startNewLine` and ⌥⌘↵ to `insertLineAbove` in the IntelliJ preset, and unbind ⌘↵ / ⇧⌘↵ there.

### 1.7 Find Next / Find Previous (⌘G / ⇧⌘G)

- `FindPanelController.selectNextMatch` exists. Add `.findNext` and `.findPrevious` that work whether or not the panel is visible, using the last query (`FindSession`); with no query they open the panel.

---

## Phase 2: Navigation and intelligence

### 2.1 Go to Next / Previous Problem (F2 / ⇧F2)

- **As built:** `EditorActionID.goToNextProblem` / `goToPreviousProblem`, handled in Umbra by chaining `editorActionHandler` (`IDEEditorPaneHost.wireProblemNavigation`, like `wireHTTPActions`) into `IDEWorkspace.goToProblem(forward:)`, which opens the row with the Problems panel's own `openProblem`. The choice of row is the pure `ProblemNavigator` in `EditorIntelligence`. Errors and warnings only, and only those the Problems tab's severity filter shows; problems are ordered by file path, then line, then column, so the order across files is alphabetical, not "files with problems nearest the active tab". Problems starting at the same place are one stop. With nothing to go to, the hint says "No problems" or "No more problems" (only the caret's own problem left). Menu items "Next Problem" / "Previous Problem" are in the Go menu, F2 / ⇧F2 in the IntelliJ column; whether SwiftUI accepts a bare function-key shortcut on a menu item has not been checked in the running app.
- Original plan: `EditorActionID.goToNextProblem` / `goToPreviousProblem`, handled in Umbra by chaining `editorActionHandler` (the pattern at `IDEEditorViews.swift:86`, `wireHTTPActions`).
- Source of truth is `IDEProblemsStore.files` (merged, deduped and sorted by `DiagnosticGrouping`). Order: the next problem after the caret in the active file; after the last one, the first problem in the next file that has any. Resolve positions with `ProblemLocator.nsRange(for:in:)`, not `utf16Offset`.
- Respect `visibleSeverities`; by default step through errors and warnings, not hints. When there are none, show the existing short hint next to the caret.
- Cross-file jumps use the same open-and-reveal path as a Problems panel row.

### 2.2 Go to Type Declaration (⌃⇧B)

- **As built:** `NavigationKind.typeDefinition`, `EditorActionID.goToTypeDefinition`, wired next to `goToDefinition`. `JavaGoToTypeDefinition` (`Sources/JavaIntelligence/Navigation/`) types the call, field access or name under the caret with the existing `JavaExpressionTyper` (so generic substitution works: `Box<Baz>.get()` → `Baz`) and, at a declaration name, reads the declared type (`var` and implicit lambda parameters use the inferred local type). A type reference, `new Foo()`, `this` and `super` go to the type. Limits: at a use site a value whose type is a type variable resolves to the variable's bound, not to the type parameter (only its declaration reaches the parameter); wildcard and primitive types have no declaration.
- Original plan: add `NavigationKind.typeDefinition` (`EditorIntelligence`) and `EditorActionID.goToTypeDefinition`, wired in `EditorIntelligenceController` next to `goToDefinition`.
- Java: `JavaGoToTypeDefinition` in `Sources/JavaIntelligence/Navigation/`. Use `JavaSymbolIdentity` to classify the symbol (local, parameter, field, method, constructor, type), take its declared or return type (an expression's type from `JavaExpressionTyper`), and hand it to the existing definition resolution (source, attached sources, or decompile with the existing consent flow). Generics resolve to the outer type; primitives and unresolved types show the "nothing found" hint.
- `JavaGoToDefinitionProvider` is primary for `.java` for every kind. Add the new kind to its `isPrimary` set so a name-matching fallback can't answer.
- LSP: `LSPClient.requestTypeDefinition` (`textDocument/typeDefinition`) and an `LSPTypeDefinitionProvider`, modelled on `LSPImplementationProvider`.
- Tests: locals, fields, method returns, generics, arrays, `var`.

### 2.3 Parameter Info (⌘P)

- **As built:** `.showParameterInfo` in `EditorIntelligenceController` asks the `SignatureHelpProviding` at the caret and shows the hints, or the hint "No parameter info here" when the caret is not in a call. It needed no Java change: `JavaExpressionTyper` finds the enclosing call by scanning back from any offset, and tests now cover a caret mid-argument, before later arguments, and outside a call. In Umbra it is a Java-menu item (⌘P in the IntelliJ column). Only the automatic trigger after `(` and `,` refreshes the hints as typing continues; the manual one shows them once.
- Original plan: signature help auto-triggers on `(` and `,`; add `.showParameterInfo` to request it explicitly from anywhere inside the argument list, and check that `JavaSignatureHelp` accepts an arbitrary caret inside a call.

### 2.4 Symbol scopes (⌘F12 file structure, ⌥⌘O workspace symbol)

- **As built:** two actions. `goToFileSymbol` (⌘F12 in the IntelliJ preset, "File Structure…" in the Go menu) opens a new palette mode, `EditorPaletteMode.fileSymbols`, served by `FileSymbolsPaletteProvider`: the declarations (functions, types, variables, properties) of the focused document from `SymbolIndex.symbols(in:)`, in source order, all listed on open and narrowed by typing. `CommandPaletteController.activeDocumentIDProvider` tells it which document; Umbra sets it from the active pane. `goToSymbol` is unchanged (⌥⌘O in the IntelliJ preset); it still searches the symbol index. Sublime and Default keep ⌘R on `goToSymbol`; Sublime's own ⌘R is a per-file list, so pointing that key at File Structure would be more faithful, but it would change behaviour those presets have today, so I left it.
- Limit found: Umbra's `SymbolIndex` is fed by *open* documents, so `goToSymbol` finds symbols in open files, not in every project file. Project-wide methods and fields for Java would need a member search over `JavaIndex` (only classes are searched today, in the Classes tab), which is a separate, larger item.
- Original plan: `goToSymbol` today opens the `@`-scoped palette. Give it a scope parameter: current file (`@`, backed by the document's symbols) or workspace (`SymbolSearchEngine` plus `IDEJavaClassesPaletteProvider` for Java classes). Add two action IDs so each can be bound (`goToFileSymbol`, `goToSymbol`).

---

## Phase 3: Run and debug

Today: launch, breakpoints, Resume, Step Over, Stop, call stack and locals (`JavaDebugSession`, `IDEDebugPanel`, and the JDI adapter at `Example/Umbra/Tools/JavaDebugAdapter/src/main/java/com/umbra/debug/DebugAdapter.java`). The adapter's `handle` switch supports `launch`, `attach`, `setBreakpoint`, `clearBreakpoint`, `resume`, `stepOver`, `stackFrames`, `localVariables` and `disconnect`.

### 3.1 Step Into and Step Out (F7 / ⇧F8)

- **Adapter:** generalize `stepOver()` into `step(depth)` using `StepRequest.STEP_INTO` / `STEP_OUT` (the `stepOver` body is the template: delete existing step requests, create one, `addCountFilter(1)`, resume). Add `stepInto` and `stepOut` to `handle`.
- For step-into, add class exclusion filters (`java.*`, `jdk.*`, `sun.*`) so stepping doesn't enter JDK internals by default.
- **Swift:** `JavaDebugSession.stepInto()` / `stepOut()`, two buttons in the panel toolbar.

### 3.2 Pause (no IntelliJ key)

- **Adapter:** `pause` calls `vm.suspend()`, picks the thread to report (main thread first), and emits the same stopped event the breakpoint path uses.
- **Swift:** `JavaDebugSession.pause()`, enabled while running. Menu item and toolbar button only.

### 3.3 Evaluate Expression (⌥F8) and Quick Evaluate (⌥⌘F8)

- JDI has no expression evaluator, so the scope is stated honestly. Supported: local and field paths (`a`, `a.b.c`, `this.x`, `arr[i]` with a literal or local index), literals, and `toString()` via `ObjectReference.invokeMethod` on the suspended thread for display. Unsupported, and said so in the result: method calls with arguments, arithmetic, lambdas. Full evaluation would need in-target compilation and is out of scope.
- **Adapter:** an `evaluate` command with `expression` and `frameIndex`, returning the same shape `localVariables` returns (name, type, value, children) so the panel's rendering is reused.
- **UI:** Quick Evaluate evaluates the selection, or the word at the caret, and shows a popover at the caret. Evaluate Expression opens a small input field in the debug panel.

### 3.4 Run in Context (⌃⇧R) and Debug in Context (⌃⇧D)

- Reuse `JavaRunConfigurationStore`, the `.classpathMain` target and the Java test decorations from `refreshJavaTestDecorations`. A `main` method gives a `.classpathMain` configuration for its class; a test method or class gives the test run the gutter already offers. Create a temporary unsaved configuration and select it in the toolbar picker. Neither in context: fall back to Run Last Configuration.

### What planning missed: the debugger did not work at all

Building 3.1 and 3.2 meant driving the adapter against a real JVM for the first time, and that showed the existing debugger could not have run. Fixed in `Example/Umbra/Tools/JavaDebugAdapter`, with `JavaDebugAdapterTests` (`Tests/PenumbraTests/`) now driving it end to end (skips without a JDK):

- **No `Main-Class` in the jar**, so `java -jar` refused to start the adapter. `build.sh` now sets it.
- **The jar needed Java 26.** It was compiled by the building JDK and runs on the *project's* JDK. `build.sh` now uses `--release 17`, and the rebuilt jar was run on JDK 21.
- **`launch` attached before the JVM listened** ("Connection refused"). It now retries until the port opens, or reports that the program exited first. The target's output is drained (it filled its pipe and could block the program) and forwarded as `output` events, which the app ignores for now.
- **Breakpoints only worked in classes already loaded.** With a JVM started suspended nothing is loaded yet, so they were silently lost. They are now kept and placed as each class is prepared.
- **Source files were matched against the adapter's working directory**, so any packaged class failed to match. They now match by path suffix, and the adapter resolves a stop's file to an absolute path from the breakpoints and from source roots the app passes (Gradle source sets plus the project folder).
- **A stop resumed itself:** the event loop resumed the event set right after reporting a stop. Stops now hold until Resume or a step.
- **The launched JVM was never resumed** after breakpoints were set (`suspendOnStart` is on by default). `JavaDebugSession.start` now sends `resume`.
- **Opening the stop location** was not implemented: the panel showed only a line number. The workspace now opens the file and selects the line on a stop (`revealDebugStop`).

Not touched, and not verified: `attachForGradle` resumes only `if !suspendOnStart`, which looks inverted for a JVM that Gradle starts suspended. The Gradle debug path was not exercised.

### 3.5 Run menu and keys

- Move run and debug items out of the Java menu into a top-level **Run** menu: Run, Debug, Run/Debug in Context, Stop (⌘F2), Resume (⌥⌘R), Step Over/Into/Out (F8/F7/⇧F8), Pause, Toggle Breakpoint (⌘F8), Evaluate, Quick Evaluate.
- **As built:** a top-level **Run** menu (Run/Debug Last Configuration, Edit Run Configuration…, Toggle Breakpoint, Resume, Pause, Step Over/Into/Out, Stop), moved out of the Java menu; step and resume items are enabled only while stopped, Pause only while running, and the debug panel has matching buttons. IntelliJ column: F8 / F7 / ⇧F8, ⌥⌘R Resume, ⌘F2 Stop, ⌘F8 Toggle Breakpoint; Pause has no key. Run in Context and Evaluate are not in the menu yet.
- Existing keys ⌃⌥R / ⌃⌥D for Run/Debug Last Configuration are left as they are. Keys go in the menu table from phase 0, IntelliJ column only, so Sublime and Default users see no change.

---

## Phase 4: Git

Facts found while planning: `GitRepository.blame(relativePath:contents:)` **already exists** in `Packages/GitIntelligence` (returning `[GitBlameLine]`), and nothing in Umbra calls it. `GitRepository.log` has no per-path filter. There is no revert. Push and pull exist in `IDEGitStatus` and have no shortcuts.

### 4.1 Toggle Git Blame (Annotate, no IntelliJ key)

- Call `GitRepository.blame` with the live buffer contents, so blame follows unsaved edits, off the main thread, debounced and cancellable, one request per document version. Drop stale results.
- **Display:** preferred is a narrow annotation column in the gutter (author and relative date, commit and message in a tooltip). The gutter API checked in `Sources/Penumbra/TextView/Gutter`: `GutterDecoration` (a clickable SF Symbol per line, `setGutterDecorations`) and `GutterLineMarker` (a fixed set of override/implement icons) exist, but neither draws text. So blame needs a small new display-only text-annotation API in Penumbra with no git types. Fallback: an end-of-line annotation on the caret line only.
- Drawing cost is bounded by visible rows. Edits shift the line entries and mark edited lines "uncommitted".
- Menu item under a new **Git** menu, plus Find Action. The toggle is per document and not persisted at first.

### Phase 4 as built

- **`GitRepository`** gained `log(… path:)` (`git log --follow -- <path>`), `existsInHead(relativePath:)` and `revertToHead(paths:)` (`git restore --source=HEAD --staged --worktree`), with real-git tests including a rename and a deleted file.
- **File History:** `IDEGitStatusModel.showFileHistory(path:)` narrows the History tab to that file's commits (no graph lanes, since a filtered log has dangling ones); a header with "All Commits" returns to the full history. Selecting a commit shows that file's diff, or the whole commit when the file was renamed in it (a per-file diff under the new name is empty for those). Git menu: "Show History for File", no key.
- **Revert (⌥⌘Z):** Git menu "Revert File…" asks first, with Cancel as the default answer, and says unsaved edits go too. It refuses a file that is untracked or only staged as new (no committed version to go back to) with a dialog saying why. After the restore the open tab reloads from disk even if it had unsaved edits (`reloadOpenEditorsAfterGitChange(discardingEditsIn:)`). Scope is the active file; a multi-file revert from the Source Control panel is not built.
- **Pull / Push:** ⌘T and ⇧⌘K in the IntelliJ column, menu items "Update Project (Pull)" and "Push" (disabled outside a repository). They reuse `IDEGitStatusModel.pull()`/`push()` and switch to the Source Control tab so the outcome is visible. Pull still refuses while any open file in the repository has unsaved edits, as before. There is no ⌃G chord group and no VCS popup; the menu and Find Action cover them.

### 4.2 File History (no IntelliJ key)

- Add a `path: String?` parameter to `GitRepository.log(...)`, running `git log --follow -- <path>`, with a test against a fake `GitRunning`.
- Reuse the Source Control panel's commit list and diff viewer (`commitDiff(hash:path:)` exists). Add a "File History" mode with a header naming the file and a back button.

### 4.3 Revert (⌥⌘Z)

- Add `GitRepository.restore(paths:)` (`git restore --source=HEAD --staged --worktree`). Untracked files are not touched unless the user confirms a second, explicit prompt.
- Always confirm, naming the file(s) and stating that changes are lost. No "don't ask again", since this is destructive.
- Handle the open buffer: mention unsaved edits in the same dialog; after the revert, reload from disk keeping the caret line where possible, and refresh git status.
- Scope is the active file; the Source Control panel gets a per-file "Revert" for several files.
- Test only on a scratch repository.

### 4.4 Push and Pull keys

- Push ⌘⇧K, Update Project ⌘T, as menu items in the new Git menu, reusing `IDEGitStatus.push()` / `pull()`. Both keep refusing to run with unsaved buffers (`refuseUnsaved(before:)`).
- Optional: a VCS operations popup (⌃V in IntelliJ) listing blame, file history, revert, pull, push and commit. Cheap to build as a palette scope; do it only if the Git menu proves hard to reach.

---

## Phase H: HTTP request play button (play.fill gutter icon)

IntelliJ's HTTP client shows a green run arrow beside every request in a `.http` file. Umbra gets the same: a `play.fill` icon in the gutter on the first line of each request; clicking it sends that request. This is small because the pieces exist.

**What exists**
- `GutterDecoration(line:symbolName:accessibilityLabel:)`, `TextView.setGutterDecorations(_:)` and `TextView.gutterDecorationHandler` (a click on a decoration calls the handler with its 1-based line). Java tests already use `play.circle`, and breakpoints use `circle.fill`, through `IDEWorkspace.refreshJavaTestDecorations`.
- `HTTPRequestParser` (tree-sitter HTTP grammar) with a private `collectRequests(from:)`, and `IDEHTTPSupport.send(text:caretUTF16Offset:fileURL:)`, which parses the request at a caret offset.

**Plan**
1. **Request positions.** In `HTTPRequestParser`, add `requestStartLines(in text:) -> [Int]` (1-based line of each `request` node's first line) and `send` variants keyed by an offset. Reuse the existing parse; no second grammar pass.
2. **Decorations.** For a document whose `languageIdentifier` is `http`, set one `GutterDecoration(line:, symbolName: "play.fill", accessibilityLabel: "Send Request")` per request. `GutterDecorationView` already tints every icon with one `iconColor` (default `systemGreen`), so no tint API is needed; per-icon colours would need one.
3. **Click.** The handler maps the clicked line to the request whose start line it is, sets the send offset to the start of that line, and calls `IDEHTTPSupport.send(...)`, then shows the HTTP response tab as `sendActiveHTTPRequest` does. A request already in flight is cancelled first, as `send` already does. The caret does not move.
4. **One owner for gutter decorations.** `refreshJavaTestDecorations` currently clears decorations and the handler for any non-Java file (`setGutterDecorations([])`, handler `nil`), which would erase the HTTP icons. Refactor it into a `refreshGutterDecorations(for:)` that picks the language's provider (Java: breakpoints and test icons, unchanged; HTTP: play icons), so each language builds its list and its handler in one place. Breakpoints stay Java-only.
5. **Refresh timing.** Decorations are refreshed on the same 300 ms debounce as Java (`refreshJavaRunAvailability`), on document open and on tab switch. Until the refresh lands after an edit, icons may sit one edit stale; first check whether `TextView` shifts decorations with edits the way `GutterLineMarkerStore` shifts line markers, and if it doesn't, note the limitation in the PR.
6. **Fix the hot path while here.** `refreshHTTPSendAvailability` calls `HTTPRequestParser.canParseRequest` with `textView.text` on every selection change, which copies and parses the whole buffer on the caret path and breaks the performance rule (no `textView.text` on a hot path). Derive `httpFileCanSend` from the cached request ranges from step 1, refreshed on the debounce: the caret is inside a request's range. Drop the per-selection parse.
7. **Keys.** Send Request keeps its menu item, its Find Action entry (`app.http.sendRequest`) and the `sendHTTPRequest` action. Keys: ⌃↵ in the IntelliJ preset; ⇧⌘R in Sublime and Default (see the key map). The gutter icon works regardless of preset.
8. **Accessibility and tooltip.** VoiceOver label "Send Request"; tooltip `GET https://…` if the decoration view supports tooltips (`GutterLineMarker` has one, `GutterDecoration` does not, so add an optional tooltip or skip).

**Tests**
- `HTTPRequestParserTests`: start lines for one request, several requests separated by `###`, a request with a body, variable-only files, an empty file.
- A workspace-level test that a `.http` document yields the expected `GutterDecoration`s, and that a Java document's decorations are unchanged by the refactor.
- Click mapping: clicking a non-request line does nothing.

Effort: S–M. No dependency on the other phases apart from phase 0 for the ⌃↵ menu key.

---

## Phase 5: Replace in Files (⇧⌘R)

**As built** (the numbered plan below still describes the intent):

- **Planner (`EditorIntelligence`):** `ProjectReplacePlanner.entries(for:replacement:in:url:)` returns one `WorkspaceEditPlanEntry` per match that the replacement would change (a match replaced by itself is left out). `WorkspaceSearchQuery.compiledRegularExpression()` is now the one place a query becomes a regex, and `ProjectSearchEngine` uses it, so what Replace changes is exactly what the search listed (a test checks the two agree on offsets and lines). In regex mode the replacement is an `NSRegularExpression` template (`$1`, `$0`); otherwise it is literal, so `$` and `\` mean nothing. Offsets are UTF-16, checked with accents and emoji, and lines with CRLF.
- **Options:** the drawer now has Match Case (`Aa`), Whole Word (`W`) and Regular Expression (`.*`) toggles, and searching honours them (`searchProject` gained `isCaseSensitive:`); toggling re-runs the search. A replace row (`arrow.left.arrow.right` button, or ⇧⌘R) holds the replacement and a **Replace All…** button. An invalid regex says so instead of searching.
- **Flow (`IDEWorkspace.replaceInFiles`):** the search only picks the files. Each is read as it is *now*: the open editor's text if there is one, else disk (off the main actor). The plan goes through the same preview sheet Rename uses, where entries can be unchecked, then through `IDEWorkspaceEditApplier`. Open files are edited in their editors and left unsaved; the rest are rewritten atomically inside the project folder only. Warnings say so, and when the search hit its 2,000-match cap or a file wasn't UTF-8.
- **Last check (`IDEReplaceInFilesGuard`):** immediately before applying, each edit is compared with the file's current text (buffer or disk). An edit whose planned text is no longer at its range is dropped and reported per file ("N replacements skipped: the file changed since the search"), never applied at a drifted position. Pressing Apply again after a partial failure is safe for the same reason.
- **Not built:** a file mask or scope, "replace in selected files only" (uncheck entries in the preview instead), and a preview of the *new* line text next to each match (the sheet shows what Rename shows). A file that is open with unsaved edits is planned against the editor's text, so a match that exists only on disk is not found.


Find in Files runs on `EditorIntelligence.ProjectSearchEngine` and shows in `FindInFilesPanel`. Rename already has a preview-and-apply path this reuses.

1. Add a replace field and options (case, whole word, regex) to `FindInFilesPanel`, and a "Replace All…" button.
2. Build a `WorkspaceEdit` from the result set: one `TextEdit` per match with the expanded replacement. Regex captures (`$0`, `$1`) use the expansion `BatchReplaceSet` and `SearchQuery` already use, so results match in-file replace.
3. Show it in `IDEWorkspaceEditPreviewSheet`, which has per-file and per-match checkboxes.
4. Apply with `IDEWorkspaceEditApplier` (live buffers via `TextEditApplicator`; closed files written atomically inside the project folder). Files with unsaved edits get the change in their live buffer and stay dirty.
5. Safety: never write outside the project root; skip whatever Find in Files already excludes (binary, ignored); re-verify each match against current content right before applying, so a file changed since the search is skipped and reported, never corrupted.

**Key conflict (decided):** ⇧⌘R is hard-coded for HTTP "Send Request" today. The IntelliJ preset honours IntelliJ, so ⇧⌘R is Replace in Files there, and Send Request moves to ⌃↵ (the key JetBrains' HTTP client uses to run the request at the caret) in the IntelliJ column of the menu table. Sublime and Default keep ⇧⌘R for Send Request and get no key for Replace in Files. This depends on phase 0 making menu keys per preset.

---

## Phase 6: Layout, tool windows and view

### Phase 6 as built (differences from the text below)

- **Tabs:** ⇧⌘] / ⇧⌘[ in *every* preset (the macOS standard), through `IDEWorkspace.selectAdjacentTab`, reusing `TabListEngine.nextIndex`/`previousIndex`.
- **Splits:** `focusAdjacentPane` cycles `flattenedPanes()` in layout order; ⌥⇥ / ⌥⇧⇥ in the IntelliJ column only.
- **Tool windows:** ⌘5 opens the Debug tab (only once a session has started); Hide All (⇧⌘F12) remembers which sidebars and whether the bottom panel were showing and restores exactly those on the second press. Nothing was added for ⌘1-⌘9 beyond Phase 0's.
- **Zoom:** `IDEPreferences.zoomPercent`, session-only, 10% steps from 50% to 300%, applied by rebuilding the editor theme at `fontSize × zoom`; the terminal keeps its own size. View menu: Zoom In / Zoom Out / Actual Size. Sublime and Default get ⌘= and ⌘-; the IntelliJ column has none, because ⌘= and ⌘- fold there.
- **Clear Terminal:** feeds the terminal the clear-screen and clear-scrollback escapes, then sends Ctrl-L so the shell redraws its prompt. ⌘K is claimed by `IDETerminalHostView.performKeyEquivalent` only while that terminal is first responder, in every preset (it is also the ⌘K ⌘D chord prefix in editors). There is a View-menu item and a Find Action entry with no key.
- **Go to Tool Window (6.6):** a generic `ToolWindowsPaletteProvider` and palette mode `.toolWindows` in Penumbra (`CommandPaletteController.toolWindowEntriesProvider`, action `goToTool`), fed by `IDEWorkspace.toolWindowEntries()` with the windows that exist right now (Project, Structure, Gradle, Terminal, Problems, Source Control, Debug, Usages, hierarchies, test results, Gradle Output, HTTP Response). Choosing one opens it and never toggles it shut. It also appears in Search Everywhere. No new sigil: the plan's `!` scope was dropped, since a dedicated action covers it. Go menu: "Tool Window…", no key.
- **Emoji (6.7):** nothing to build. Umbra replaces only the New/Undo groups and adds after Paste, so the system's Emoji & Symbols item stays, and `TextInputView` implements `insertText(_:replacementRange:)`. Not run.
- Not checked in the running app: the ⌘K hand-off (SwiftTerm may claim the key first), the tab/split switching, and the zoom repaint.

### 6.1 Next / Previous Tab (⇧⌘] / ⇧⌘[)

- `EditorPane` has `selectDocument` and tab history. Add `IDEWorkspace.selectNextTab()` / `selectPreviousTab()` that cycle `activePane` documents in tab-bar order, wrapping. First check that nothing equivalent already exists in `IDEEditorTabsBar`.

### 6.2 Next / Previous Split (⌥⇥ / ⌥⇧⇥)

- `EditorWorkbench` has the layout tree. Add `focusNextPane()` / `focusPreviousPane()` cycling in layout order and moving first responder to that pane's text view.

### 6.3 Tool window keys

- Menu-table entries only, for the existing toggles: ⌘1 Explorer (`toggleSidebar`), ⌘5 Debug, ⌘6 Problems, ⌘7 Structure (already), ⌘9 Source Control, ⌥F12 Terminal, ⇧⌘F12 Hide All. `toggleBottomToolWindow(_:)` exists at `IDEWorkspace.swift:1937`. Add a `hideAllToolWindows` that remembers what was open and restores it on the second press.

### 6.4 Zoom In / Out / Reset

- IntelliJ has no default key, and ⌘+/⌘- are Collapse/Expand there, so zoom has no key in the IntelliJ preset. Add `zoomIn` / `zoomOut` / `resetZoom` to View. They change a session zoom factor applied on top of `preferences.fontSize` (clamped, say 50%–300%), show the level briefly in the status bar, and reapply through the existing `applyLivePreferences` path. Not persisted; the saved size stays in Settings.

### 6.5 Clear Terminal (⌘K while the terminal is focused)

- `IDETerminalPanel` uses SwiftTerm. Add `clearTerminal()` on the focused terminal: reset the screen and scrollback, then send Ctrl-L so the shell redraws its prompt. Bind ⌘K only while the terminal is first responder; add it to the terminal context menu and the View menu.

### 6.6 Go to Tool (no key)

- A `SearchEverywhereProvider` (the host-extensible protocol in `Sources/Penumbra/Workbench/CommandPalette/`) listing the tool windows: Explorer, Structure, Gradle, Terminal, Problems, Usages, Hierarchy, Source Control, Debug, HTTP, Test Results. Selecting one calls the existing `select…Tab()` / `toggle…()`. Reachable from Search Everywhere (⇧⇧) and a new palette sigil (e.g. `!`).

### 6.7 Emoji & Symbols

- macOS provides this through the standard Edit menu (`orderFrontCharacterPalette`). Verify the custom `.pasteboard` and Edit groups in `UmbraApp.swift` still expose it, and that `TextInputView` accepts what it inserts. Likely no code.

---

## Phase 7: Generate Code with AI: needs a decision

IntelliJ has no matching default key, and this is the only item with policy questions, so it goes last and should not start before they are answered.

What exists: `EditorIntelligence/AI` has `AITextModel`, `AICompletionProvider` and `AIHoverProvider`. Umbra has no model implementation, settings or UI for them.

Open questions:

1. **Provider:** Anthropic API, a local model, or a user-supplied endpoint? The App Store rule allows no hidden network calls, so the feature must be off by default and need the user's own credentials and explicit opt-in.
2. **Credentials:** Keychain only, never `UserDefaults` or `IDEPreferencesSnapshot` (which is exported).
3. **Disclosure:** a first-use sheet stating exactly what is sent (the selection, the prompt, optionally surrounding file text), like `JavaDecompilerAgreement` and the trust prompts.
4. **UX:** an inline prompt bar at the caret that streams a diff preview to accept or reject in one undo step, rather than writing into the buffer.
5. **Key:** pick one, or leave it to Find Action.

If settled: an `AITextModel` conformance in Umbra, a Settings pane (provider, model, key, opt-in, context size), the prompt bar, a diff preview reusing the rename preview components, and a `generateCode` action. Recommendation: a separate design doc after phases 0–6.

---

## Delivery order and effort

| Order | Item | Effort | Depends on |
|---|---|---|---|
| 1 | 0 Menu shortcuts per preset, IntelliJ gap fixes | M | none |
| 2 | 1.6 Start New Line keys, 1.7 Find Next/Prev | S each | 0 |
| 3 | 1.2 Matching brace, 1.4 Unselect occurrence | S each | 0 |
| 4 | H HTTP request play.fill gutter icon | S–M | 0 (⌃↵ key only) |
| 5 | 1.1 Block comment, 1.3 Folding commands | M each | 0 |
| 6 | 2.1 Next/prev problem, 2.3 Parameter info, 2.4 Symbol scopes | S each | 0 |
| 7 | 3.1 Step into/out, 3.2 Pause, 3.5 Run menu | M | 0 |
| 8 | 6.1–6.5 Tabs, splits, tool-window keys, zoom, Clear Terminal | S each | 0 |
| 9 | 2.2 Go to Type Declaration | M | none |
| 10 | 1.5 Complete Statement | M–L | 1.x helpers |
| 11 | 4.2 File history, 4.3 Revert, 4.4 Push/pull keys | M | 0 |
| 12 | 5 Replace in Files | M | 0 (for the ⇧⌘R menu key) |
| 13 | 3.3 Evaluate, 3.4 Run in Context | M–L | 3.1 |
| 14 | 4.1 Git blame (gutter annotations) | L | new gutter text-annotation API |
| 15 | 6.6 Go to Tool | S | none |
| 16 | 7 Generate Code with AI | L | decision |

S is under a day, M is 1–3 days, L is more than 3 days. These are rough.

## Verification

Per phase:

- Unit tests in `Tests/PenumbraTests` for every new action, using `MockTextInput` and the existing text-view fixtures, with multi-caret and single-undo-step assertions for every editing action.
- `swift build` and `swift test` clean. Run `swift test --filter KeymapTests` and `IntelliJKeymapTests` after each phase.
- For 1.1, 1.3 and 1.5, run `swift run -c release PerfHarness enter-session synthetic --lines 20000` (and 120000) on the parent commit and on the change, and record both. Do not draw conclusions from Debug timings.
- For phase 3, exercise the adapter by hand against a small Java project (breakpoint → step in → step out → pause → evaluate) and record the result in the PR; the JDI adapter has no automated harness.
- Update CLAUDE.md's feature list (IntelliJ keymap bindings, the new actions, the Run and Git menus) as each phase lands, and update the Status table above.
