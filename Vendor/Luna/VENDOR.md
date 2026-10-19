# Vendored: Luna

- Origin: https://github.com/lukilabs/beautiful-mermaid-swift
- Commit: 6a23a29e91af8f5b3e9fc09945332ca193bd69ec (2026-04-27)
- License: MIT (see LICENSE)
- Copied as source; not an SPM git dependency.
- Renamed from `BeautifulMermaid` to `Luna` (target `PenumbraLuna`,
  path `Vendor/Luna/Sources/Luna`). Upstream links and credit in `README.md`
  still name the `beautiful-mermaid-swift` project they point at.
- Layout engine: Luna-owned layered layout in `Sources/Luna/Mermaid/src_luna_layout.swift`
  (longest-path layering, barycenter crossing minimization, orthogonal routing,
  recursive compounds). The former ElkSwift (EPL-2.0) dependency is removed;
  Luna is MIT-only. The dictionary interchange (`ElkNode`, `children`,
  `edges`/`sections`) intentionally mirrors the ELK JSON shape the graph
  builders and extractors were written against.

## ELK decision (recorded, executed)

Replaced the vendored ELK engine with the Luna-owned layered core above
(option B from the Luna plan): Pele, the parse oracle for Mermaid 12.1.0
coverage, bundles no layout engine of its own, and Mermaid itself treats
`flowchart-elk` as a first-class layout — so graph diagrams (flowchart,
state, class, ER, architecture/C4) keep a real layered layout, now without
the EPL-2.0 tree. Pele supplies syntax coverage and geometry conventions,
not node placement or edge routing; Luna supplies the latter itself.
