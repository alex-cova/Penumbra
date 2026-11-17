# Language servers (catalog)

Umbra drives 14 external language servers (15 languages: one `clangd` serves C and C++) through one shared LSP stack. Java stays on its native engine; Swift (SourceKit-LSP), TypeScript and Python (`pylsp`) keep their own definitions.

## Architecture

| Layer | Where | Notes |
|---|---|---|
| JSON-RPC, framing, requests, capabilities, document sync | `Sources/EditorIntelligenceLSP` (existing) | Built on the `LanguageClient`/`JSONRPC` packages. Not reimplemented. |
| Process, trust, restart backoff, status | `Umbra/Sources/Umbra/LanguageServers/IDELanguageServerHost.swift` (existing, extended) | One process per server id per window. |
| **Declarative registry** | `LanguageServers/Catalog/IDELanguageServerCatalog.swift` | One `IDELanguageServerSpec` per server: languages, executables, arguments, markers, install guidance, licence. |
| Discovery | `Catalog/IDEServerLocator.swift` | override, project-local, process `PATH`, login-shell `PATH`, Homebrew, toolchain directories. |
| Relevance | `Catalog/IDEServerProjectProbe.swift` | Bounded scan (400 entries for markers at the root and one level down, 1,500 entries / 3 levels for sources). |
| Settings | Settings ▸ Language Servers (`IDELanguageServersSettings`) | Per-server on/off, path override, Restart, version, last stderr, install commands. Stored as `umbra.languageServers.<id>.{enabled,path}` in `UserDefaults`. |

**Adding a language** = one spec in the catalog + one `LanguageDefinition` in `LanguageDefinition+BuiltIns.swift` (extensions → identifier) + tests. No completion, diagnostics or sync code.

## Changes to shared code made for this work

* `IDELanguageServerHost`: `failed` phase and `maxRestartAttempts` (5) so a server that dies at once is no longer restarted forever; a server that ran 60 s before dying gets a fresh budget; stderr tail kept in `serverErrors`; per-server `restart`/`stop`; a per-process serial so a replaced process's exit cannot clear its successor.
* Document sync now starts after the host's `initialize` completes. Before, `didOpen` for a slow server (clangd) was sent too early and dropped, so every request failed with "non-added document" (found by the real-clangd test).
* `LanguageServerClient.capabilities()` is single-flight. Two concurrent callers could leave one with no capabilities and a "ready" server advertising no features.
* Identity-only `LanguageDefinition`s added for PHP, Scala, Zig, Terraform, Ruby, R, Lua, Dart and C# extensions (no grammar: highlighting stays plain).

## Compatibility matrix

Server choices were checked against each project's documentation and, for Kotlin and C#, a web search on 2026-11-16. Licences are as stated by the projects; re-check before redistributing. Umbra bundles none of them and never installs one.

| Language | Server | Launch | Needs | Install | Licence |
|---|---|---|---|---|---|
| PHP | Intelephense | `intelephense --stdio` | Node.js | `npm i -g intelephense` | Proprietary, free tier; premium needs a key |
| Rust | rust-analyzer | `rust-analyzer` | rustup toolchain | `rustup component add rust-analyzer` | MIT/Apache-2.0 |
| C# | csharp-ls | `csharp-ls` | .NET SDK | `dotnet tool install --global csharp-ls` | MIT |
| Kotlin | JetBrains kotlin-lsp (alpha) | `kotlin-lsp --stdio` (flag unverified) | JDK 17+ | `brew install JetBrains/utils/kotlin-lsp` | see repo |
| Scala | Metals | `metals` | JDK 17+, build tool | `cs install metals` | Apache-2.0 |
| Zig | ZLS | `zls` | matching Zig | `brew install zls` | MIT |
| Terraform | terraform-ls | `terraform-ls serve` | Terraform CLI | `brew install hashicorp/tap/terraform-ls` | MPL-2.0 (confirm) |
| Ruby | Ruby LSP | `ruby-lsp` | Ruby 3+ | `gem install ruby-lsp` | MIT |
| R | languageserver | `R --no-echo --no-save -e languageserver::run()` | R + package | `install.packages("languageserver")` | GPL-3 (separate process) |
| Lua | lua-language-server | `lua-language-server` | none | `brew install lua-language-server` | MIT |
| Go | gopls | `gopls` | Go | `go install golang.org/x/tools/gopls@latest` | BSD-3 |
| Dart | Dart analysis server | `dart language-server --protocol=lsp` | Dart SDK | `brew install dart` | BSD-3 |
| C / C++ | clangd | `clangd --background-index --clang-tidy=false` | Xcode CLT or LLVM | `xcode-select --install` | Apache-2.0 + LLVM exception |
| Bash | bash-language-server | `bash-language-server start` | Node.js (+ShellCheck, shfmt optional) | `npm i -g bash-language-server` | MIT |

OmniSharp and Microsoft's Roslyn language server were not chosen for C#: both need more launch plumbing than a single stdio binary.

## Verification status

See the final report in the session that produced this file; the honest summary is kept in `Umbra/Tests/UmbraTests/IDELanguageServerCatalogTests.swift`: deterministic tests cover the registry, discovery, relevance, restart limits and status; **only clangd was exercised against a real server on the development machine**. The rest are mock/launch-unverified until the binary is installed (the real-server tests skip with a message when it is not).

## Known limitations

* **One root per server per window.** The server starts at the opened folder. Markers one level down make a monorepo relevant, but nested projects are not given separate server instances and `workspaceFolders` carries only the opened folder.
* **Semantic tokens are not enabled** for catalog servers (same reason as `IDEPythonServer.features`); tree-sitter keeps colouring. Languages without a grammar (PHP, Scala, Zig, Terraform, Ruby, R, Lua, Dart, C#) are therefore uncoloured.
* The LSP `languageId` mapping in `LSPLanguageConfiguration.lspLanguageID` is not applied by `LSPWorkspaceDocumentSync`, which sends Umbra's identifier (`shell` rather than `shellscript`). Servers that infer from the extension are unaffected; bash-language-server is not verified.
* Position encoding: the client does not negotiate `positionEncoding`, so UTF-16 (the LSP default) is used; UTF-8/UTF-32 are not requested.
* Extensionless scripts with a shebang are not detected as shell files.
* Server-specific settings (`workspace/didChangeConfiguration`) and a per-server initialization-options editor are not exposed; only the spec's static `initializationOptions` are sent.
* Not implemented: workspace diagnostics/pull diagnostics, linked editing, document links, selection ranges, on-type formatting, code lens from servers, file-operation notifications.
* Performance benchmarks beyond the clangd timing line (`LSPTIMING`) were not produced.
