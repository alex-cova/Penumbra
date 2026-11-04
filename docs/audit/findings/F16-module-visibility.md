# F16 — No module-aware (JPMS) visibility

- **Priority:** P2 · **Severity:** Medium · **Confidence:** Confirmed (2026-11-04) · **Provenance:** A+B
- **Status:** ✅ Done for project modules and Lombok accessors/constructors (2026-11-04); jar and JDK modules and the rest of Lombok are open · **Owner:** Unassigned

## Evidence

- Completion scoping does not model JPMS modules; Gradle `addModules` is replayed to `javac` and launches only. Same suspicion class: Lombok/annotation-processed members are invisible unless generated sources are indexed (generated source dirs are indexed read-only; the annotation-processor producing them is not modelled).
- No failing corpus case was inspected for either claim — this is code-supported, not corpus-proven.

## Root cause

Visibility is package/classpath-based; module descriptors never enter the resolver.

## Fix sketch

First prove it: build a modular fixture project and an annotation-processed fixture; run completion and record failures. If confirmed, thread module reads/exports into `JavaTypeResolver` scoping and treat processor output as a generated-source lifecycle (with F23).

## Complexity / Dependencies

M after proof. Depends on fixture work; resolver changes touch F01/F14 territory.

## Acceptance criteria

- Fixture results recorded in this file (promote to Confirmed or kill the finding).
- If confirmed: non-exported types no longer offered across module boundaries; exported ones are.

## Tests / benchmarks

- New modular + Lombok/annotation-processing fixtures in the Java test suite.

## Out of scope

Full JPMS launch/modulepath rework.

## Implementation notes (2026-11-04)

**Proof first, as the brief asked.** Two probes against the real completion provider, written to state what a modular `javac` or Lombok-aware IntelliJ accepts. Both failed on the old code, so both claims are **Confirmed**:
- Module `com.b` (`requires com.a`) was offered `Secret (com.a.internal)` although `com.a` exports only `com.a.api`. `module-info` was not read anywhere: the indexer skipped it explicitly.
- `person.` offered no `getName()`, `isActive()` or `setActive()` for `@Getter`/`@Setter` fields, so `person.getName().length()` could not be completed or typed either. One correction to the brief's premise: Lombok output is **not** a generated-source lifecycle problem (F23). Lombok edits the AST in memory and writes no `.java`, so there is nothing on disk to index; the members have to be synthesized from the annotations.

**JPMS (project modules).**
- `JavaModuleDescriptor` (`Modules/`) parses `module-info.java` (comments, annotations, `open`, `requires [transitive|static]`, qualified `exports … to`). `JavaModuleSources` caches descriptors by file date and each source root's package list by directory date.
- `JavaGradleProjectModel.moduleVisibility(forFile:paths:)`: for a file whose source root has a `module-info.java`, every module it reads (its `requires`, plus what those `requires transitive`, across the project-dependency closure) is restricted to its exported packages (a qualified export counts when this module is a target). Maven models reach it through the same projection.
- `JavaIndex.queryModules` (a task-local like `queryScope`) narrows only the **name listings**: `classes(simpleNamePrefix:)`, `classes(simpleName:)`, `classes(matching:)`, `classes(inPackage:)` and the import package pool. `classStub(qualifiedName:)` is deliberately not narrowed: a method of `com.a` may return a non-exported type and its members still resolve (tested). A class is placed in the longest of its module's packages, so `Api.Inner` follows `Api` and `com.a.api.internal` is separate from `com.a.api`.
- Wired into completion (first invocation; a second Ctrl+Space looks past it, like the classpath scope) and the import code actions.
- **Fails open**: no `module-info` (the file's source root is classpath), a module the file does not require (the editor still offers it, as IntelliJ does, and the compiler explains), a package it cannot place. Tests: `JavaModuleVisibilityTests` (12).

**Lombok (`Syntax/JavaLombokMembers.swift`, called from `JavaSourceStubBuilder.buildType` like the record members already are).** `@Getter`, `@Setter` (class and field level, `AccessLevel.NONE`/`PROTECTED`/…), `@Data`, `@Value`, `@NoArgsConstructor`, `@AllArgsConstructor`, `@RequiredArgsConstructor`, `@Accessors(fluent/chain)`. `boolean` gets `isX` (`isDone` keeps its name; its setter is `setDone`); a method you wrote wins; static fields need their own annotation; only a file that imports `lombok` counts. `JavaIndexShardWriter.formatVersion` 3 → 4 so cached shards are rebuilt with the new members. Tests: `JavaLombokMembersTests` (10, including completion and typing through a generated getter).

**Verified.** 1,786 Java library tests, including the 419-case completion corpus ratchet and the navigation corpus (which has Lombok cases), pass except two that need the JaCoCo jars (`Umbra/Sources/Umbra/Tools/JaCoCo/fetch.sh` has not been run on this machine); Umbra builds and its Java/Gradle/Maven tests pass except the same JaCoCo-dependent one.

**Not done.**
- **Jars with a `module-info.class`**: their non-exported packages are still offered. It needs a `Module` attribute reader (`ConstantPool` skips tags 19/20 today) and per-jar plumbing; automatic modules and plain jars export everything, so only modular jars are affected.
- **The JDK**: `requires java.sql` is not enforced (IntelliJ offers an unrequired module's type too, with a fix to add the `requires`), and non-exported JDK packages are handled by the `ct.sym` root (exports only) as before.
- **Lombok**: `@Builder`, `@With`, `@ToString`/`@EqualsAndHashCode` (inherited from `Object`, so completion already shows them), `@Log` fields, `val`/`var`, `@Delegate`. Navigation from a generated accessor still goes through the existing `generatedAccessorHits`; a generated method has no source range of its own.
- No annotation-processor modelling beyond Lombok (MapStruct, Dagger and friends still produce files that only exist after a build).
- The module restriction is not applied to Find Usages / rename candidates (they resolve by qualified name, not by listing).
