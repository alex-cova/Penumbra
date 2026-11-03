# F16 — No module-aware (JPMS) visibility

- **Priority:** P2 · **Severity:** Medium · **Confidence:** Strongly suspected · **Provenance:** A+B
- **Status:** Open · **Owner:** Unassigned

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
