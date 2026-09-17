# Third-party notices

Penumbra itself is licensed under the Apache License 2.0 (see [LICENSE](LICENSE)); it is a macOS port of
[simonbs/Runestone](https://github.com/simonbs/Runestone).

## Vendored markdown preview dependencies

The markdown preview (`MarkdownPreviewController`) embeds vendored sources under `Vendor/`.
These are compiled as local SPM path targets, not fetched from GitHub at build time.

| Component | Source | License |
| --- | --- | --- |
| BeautifulMermaid | [lukilabs/beautiful-mermaid-swift](https://github.com/lukilabs/beautiful-mermaid-swift) | MIT (see `Vendor/BeautifulMermaid/LICENSE`) |
| ElkSwift | [lukilabs/elk-swift](https://github.com/lukilabs/elk-swift) | **Eclipse Public License 2.0** (see `Vendor/ElkSwift/LICENSE`) |

BeautifulMermaid uses ElkSwift for graph layout. ElkSwift is **not** MIT — it remains under
EPL-2.0 in source and binary distributions. The EPL source for ElkSwift must remain available
when distributing combined works.

Textual, ConcurrencyExtras, and SwiftUIMath are also vendored under `Vendor/` for future use;
only BeautifulMermaid and ElkSwift are wired into the build today.

## Bundled Tree-sitter grammars

The `PenumbraLanguages`, `PenumbraGraphQLLanguage`, and `PenumbraMarkdownLanguage`
products embed third-party Tree-sitter grammars and highlight queries. Each grammar
keeps the license of its upstream project; all are MIT.

| Language pack | Grammar source | License |
| --- | --- | --- |
| HTML, JavaScript, JSON, Python, YAML | [simonbs/TreeSitterLanguages](https://github.com/simonbs/TreeSitterLanguages) | MIT |
| CSS, TypeScript | [simonbs/TreeSitterLanguages](https://github.com/simonbs/TreeSitterLanguages) | MIT |
| TOML, SQL, Swift, Java, Go, Bash | [simonbs/TreeSitterLanguages](https://github.com/simonbs/TreeSitterLanguages) | MIT |
| Kotlin | [fwcd/tree-sitter-kotlin](https://github.com/fwcd/tree-sitter-kotlin) | MIT |
| GraphQL | [bkegley/tree-sitter-graphql](https://github.com/bkegley/tree-sitter-graphql) | MIT |
| Markdown | [MDeiml/tree-sitter-markdown](https://github.com/MDeiml/tree-sitter-markdown) | MIT |
| HTTP | [rest-nvim/tree-sitter-http](https://github.com/rest-nvim/tree-sitter-http) | MIT |
| Mermaid | [monaqa/tree-sitter-mermaid](https://github.com/monaqa/tree-sitter-mermaid) | MIT |

The TOML/SQL/Swift/Java/Go/Bash and Kotlin `*Penumbra` wrapper targets were migrated
from Hextech's former `Vendor/PenumbraLanguages` package; the Kotlin wrapper is
hand-written to match the other language targets since simonbs/TreeSitterLanguages
does not ship Kotlin.

### simonbs/TreeSitterLanguages

```
MIT License

Copyright (c) 2021 Simon Støvring

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
