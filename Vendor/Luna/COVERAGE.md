# Luna diagram coverage (Mermaid 12.1.0 oracle: Pele)

Detector parity is measured against Pele's `detectType` table
(`pele@1/dist/pele.global.js`, Pele 1.6.0 — "supports every diagram type
built into Mermaid 12.1.0"). Every Pele key resolves to a Luna `DiagramKind`;
`DiagramKindDetector.detect` accepts a small superset (optional `-beta`
suffixes, bare `requirement`, plain `swimlane`) where harmless.

| Mermaid / Pele header | Luna kind | Path |
| --- | --- | --- |
| `graph`, `flowchart`, `flowchart-elk` | `flowchart` | ELK layered layout |
| `stateDiagram`, `stateDiagram-v2` | `stateDiagram` | ELK layered layout |
| `sequenceDiagram` | `sequenceDiagram` | dedicated layout |
| `classDiagram` | `classDiagram` | dedicated layout |
| `erDiagram` | `erDiagram` | dedicated layout |
| `xychart`, `xychart-beta` | `xyChart` | dedicated layout |
| `pie` | `pie` | extra scene |
| `gantt` | `gantt` | extra scene |
| `gitGraph` | `gitGraph` | extra scene |
| `journey` | `journey` | extra scene |
| `mindmap` | `mindmap` | extra scene (tree + radial) |
| `timeline` | `timeline` | extra scene |
| `quadrantChart` | `quadrantChart` | extra scene |
| `sankey`, `sankey-beta` | `sankey` | extra scene |
| `radar`, `radar-beta` | `radar` | extra scene |
| `treemap` | `treemap` | extra scene |
| `venn`, `venn-beta` | `venn` | extra scene |
| `packet`, `packet-beta` | `packet` | extra scene |
| `block`, `block-beta` | `block` | extra scene |
| `requirementDiagram`, `requirement` | `requirement` | extra scene |
| `architecture`, `architecture-beta` | `architecture` | extra scene |
| `C4Context`, `C4Container`, `C4Component`, `C4Dynamic`, `C4Deployment` | `c4` | extra scene |
| `kanban` | `kanban` | extra scene |
| `usecase`, `usecase-beta` | `usecase` | extra scene |
| `treeView`, `treeView-beta` | `treeView` | mindmap layout |
| `ishikawa`, `ishikawa-beta` | `ishikawa` | extra scene |
| `cynefin`, `cynefin-beta` | `cynefin` | extra scene |
| `wardley`, `wardley-beta` | `wardley` | extra scene |
| `eventmodeling` | `eventmodeling` | extra scene |
| `railroad`, `railroad-beta`, `railroad-ebnf/abnf/peg-beta` | `railroad` | extra scene |
| `info` | `info` | extra scene (title + `Luna vX` line, mirroring Pele rendering `Pele vX`) |
| `swimlane-beta` (`swimlane`) | `swimlane` | rewritten to `flowchart`, ELK layout; top-level subgraphs render as lane groups |
| `agentflow`, `agentflow-beta` (Obsidian/Pele extension, not Mermaid) | `agentflow` | rewritten to `flowchart`, ELK layout |
| `zenuml` (third-party, not Mermaid built-in) | `zenuml` | explicit `unsupportedDiagram` error |

Swimlane fidelity note: Mermaid draws lanes as full-height columns; Luna
renders them as ELK subgraph groups. Ownership ("who owns this step") is
preserved; column geometry is not. See `rewriteSwimlaneAsFlowchart`.

## Render backends (CoreGraphics default, Metal opt-in)

- `Render/Metal/` holds Luna's GPU backend: runtime-compiled shaders,
  CPU tessellation replicating every CG shape/stroke/marker formula,
  a 16 MB bounded CoreText label atlas, and `MetalDiagramRenderer`
  producing BGRA textures (+ `CGImage` readback). Vertex layout is 12
  floats per vertex (pos.xy, uv.xy, color.rgba, mode + 3 padding floats)
  matching Metal's 48-byte `DiagramVertex` array stride — see the shader
  comment; packing 9 tight floats silently corrupts every vertex past the
  first. Label quads sample the atlas top-down without a V flip (bitmap
  row 0 is the block's visual top, verified by readback).
- CG stays default everywhere (`MermaidLayer.metalBackend = false`,
  `MermaidRenderingContext.preferMetal = false`); any Metal failure falls
  back silently with a recorded reason. Export always uses CG.
- Coverage today: flowchart/state (agentflow, swimlane via `.flowchart`
  content), sequence (`MetalSequenceEncoder`), class (`MetalClassEncoder`,
  incl. segmented member colors and all markers), ER (`MetalEREncoder`,
  incl. crow's feet and key badges), XY (`MetalXYEncoder`, incl. spline
  flattening), and every extra-scene type (`MetalExtraEncoder` over the
  rect/ellipse/line/polyline/wedge/text display list). Anything else throws
  `encodeFailed`, which routes it to CG automatically.
- Parity tests per type live in `LunaDiagramTests` (`testMetalMatchesCG*`,
  mean channel diff < 6.0) against a direct-bitmap CG reference —
  `NSImage.cgImage(forProposedRect:)` resamples fractional-point diagrams
  and must not be used for pixel comparison. Each parity test also runs a
  per-label text backstop: every emitted label quad is CG-vs-Metal compared
  over a ±2px whole-quad offset search (tolerance 20.0, registration within
  1px), because the global mean dilutes missing text away. Single-line
  labels center on the measured line size exactly like CG; the atlas is
  zero-filled at creation so shelf gutters sample transparent instead of
  uninitialized-memory confetti.
- Known Metal-only approximations: rotated XY axis titles draw unrotated at
  their anchor (atlas holds axis-aligned quads); class composition diamonds
  replicate CG's inherited-default black 1px stroke quirk.
- Release numbers (200-node flowchart, 2×): parse ~51ms, layout ~4ms,
  CG raster ~30ms, Metal raster+readback ~66ms (snapshot parity holds,
  mean channel diff < 6.0). Metal one-shot raster is not faster — readback
  plus 4×MSAA resolve dominate, and >16MP refuses by design. The win needs
  direct presentation without readback (CAMetalLayer drawable); until then
  Metal stays opt-in. Parse dominates first paint either way (separate
  workstream, unaffected by backend choice).

## Flowchart token fidelity (beyond diagram coverage)

- Node shapes: all Mermaid 12.1 shapes incl. lean-right `[/ /]` and
  lean-left `[\ \]` (`parallelogram` / `parallelogram-alt` in every
  output: CG image, SVG polygon, ASCII art).
- Edge ends: circle (`o--o`, `--o`, `o--`) and cross (`x--x`, `--x`, `x--`)
  markers at either end, replacing/augmenting arrowheads; rendered in CG,
  SVG (`circle-*`/`cross-*` markers, per-color defs included) and ASCII
  (`o`/`x` glyphs). Marker model matches Pele (first char = start marker,
  last char = end marker).
- Invisible links (`A~~~B`): parsed, constrain ELK layout, but draw nothing
  in CG/SVG/ASCII; edge labels still render.
