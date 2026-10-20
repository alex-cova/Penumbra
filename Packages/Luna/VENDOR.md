# Luna provenance

- Luna is first-party code: Apache 2.0 (see LICENSE, copyright Alejandro Covarrubias), built as
  target `PenumbraLuna` from `Packages/Luna/Sources/Luna`. It is not sourced
  from any upstream repository.
- History: Luna began as a port of the OSS BeautifulMermaid surface (formerly
  `lukilabs/beautiful-mermaid-swift`) and was renamed from `BeautifulMermaid`
  to `Luna`.

## Pele ports (MIT)

The layered, compound and lane layouts, the preprocessing and the YAML subset
are ported from [obsidianmd/pele](https://github.com/obsidianmd/pele)
(MIT, Copyright (c) 2026 kepano), commit `8603bf3313ad` (Release 1.7.0).
See [NOTICE](NOTICE) for the MIT text and the list of ported files.

Pele is Luna's Mermaid 12.1.0 coverage oracle, and it ships a full layout
stack of its own: `src/layout/layered.ts` (Sugiyama), `compound.ts` (nested
groups, a direction per group, ports) and `lanes.ts` (swimlanes). Luna ports
that stack in `Sources/Luna/Layout/` (`LayeredLayout.swift`,
`CompoundLayout.swift`, `LaneLayout.swift`), plus the per-shape span rules
(`ShapeSpan.swift`, from Pele `src/svg/shapes.ts`) and the preprocessing
(`Sources/Luna/Preprocess.swift`, from Pele `src/preprocess.ts`,
`src/util/yaml.ts` and `src/text/entities.ts`).

Luna draws orthogonal polylines, so Luna always routes with `tracks: true`
and renders with the existing edge code. Pele's curve mode would need Bezier
drawing and is out of scope.

## ELK-shaped adapter

The dictionary interchange (`ElkNode`, `children`, `edges`/`sections`)
intentionally mirrors the ELK JSON shape the graph builders and extractors
were written against. It is a Luna-owned adapter over the ported engine, not
a dependency on ELK: the former ElkSwift (EPL-2.0) dependency is removed, and
Luna is Apache-2.0-only apart from the MIT-ported files above.

## Port status

Landed: typed layouts (`Layout/`), the adapter (`Mermaid/src_luna_layout.swift`),
the single compound builder (`Mermaid/src_layout.swift`), swimlane lanes, the
preprocessing/YAML subset/entities (`Preprocess.swift`), limits and located syntax
errors, and the corpus runner (`Tests/PenumbraTests/MermaidCorpus/` with
`LunaMermaidCorpusTests`). Luna draws orthogonal polylines, so routing always
runs with `tracks: true`; Pele's curve mode (Bezier drawing) is out of scope.
