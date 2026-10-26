# Harness gap 6: headless use and one shared agent library

Part of the series `agent-harness-1.md` to `agent-harness-7.md` (index: `README.md`). Checked against the code on 2026-10-26.

**Status:** open. Phase 1 (the shared library) is the enabler for the CLI and for `agent-harness-3.md`.

## What exists today

- **`UmbraACP` is already an ACP agent (server) on stdio** (`Umbra/Sources/UmbraACP/main.swift`), wrapping `AgentSession`s in AgentKit's `ACPAgentEndpoint`. It has read and edit tools plus `todo`, `ask_user`, `exit_plan_mode`, Accept Edits mode and a `SessionStore`. Config comes from flags, then `UMBRA_ACP_*` environment variables, then Umbra's UserDefaults; the key from the environment or Umbra's Keychain. Its providers are ollama, openai, chat and mlx only. It has **no command tools, no permission files, no MCP**. (An earlier version of this doc said Umbra was only an ACP client; that is wrong.)
- **The ACP client side** is `Umbra/Sources/Umbra/Agent/ACP` (`IDEACPDefinition`, `IDEACPTransport`, `IDEACPHostServices` with `fs/*` and `terminal/*`): Umbra drives external agents.
- **`Tools/AgentEval`** is an evaluator (`list`, `validate`, `run`; `--trials`, `--jobs`, `--json`, `--transcripts`). It builds its session in `TrialRunner` with `DiskAgentWorkspace`, `ReadOnlyTools` + `EditingTools` + a `run_tests` bound to the task check, and `.approveAll`. Providers: ollama, openai, chat, mlx, apple, apple-pcc. **No Anthropic and no Meta.**
- **Provider construction exists three times:** `IDEAgentSettings.makeClient(for:)` in Umbra, `makeProvider` in UmbraACP, `Providers.make` in AgentEval.
- **`Umbra/Package.swift` has only executables** (`Umbra`, `UmbraACP`) and `UmbraTests`: no library target, no products. So the command tools and permission files exist only inside the `Umbra` executable. `IDEAgentPermissionFiles`, `AgentCommandRunner` and `AgentCommandEnvironment` use only Foundation, AgentKit and SubprocessKit and could move. `IDERunCommandTool` cannot move as is: it holds `IDEAgentCommandSupport{root, box}`, the box wraps the `@MainActor` `IDEAgentHost` protocol, and the file imports JavaIntelligence.
- **No general CLI.** `UmbraMain` only handles the git password prompt (`GIT_ASKPASS`) before starting the app.
- **Root package rule.** The root `Package.swift` must keep building without AgentKit and the app, so nothing here goes there.

## Gap

- No way to run a prompt from a script, a git hook or CI, and no way to test the harness end to end without the app.
- `UmbraACP` is a second-class agent: another editor driving it gets no commands, no permission rules, no MCP, and a smaller provider list than the app.
- Every provider addition (Anthropic, Meta) has to be repeated three times.

## What Claude Code and OpenCode do

- Claude Code `-p "prompt"` prints the result and exits, with `--output-format json|stream-json`, `--max-turns`, `--allowedTools`, and meaningful exit codes. It is used in CI, git hooks and shell pipelines.
- OpenCode has `opencode run` and a server mode that other clients connect to. Both run the same permission rules as the interactive app.

## Proposal

**Phase 1: library target `UmbraAgentSupport` in `Umbra/Package.swift`.**
1. Move into it: a provider factory (every HTTP provider including Anthropic and Meta, with MLX and Apple behind the same function), `IDEAgentPermissionFiles`, `AgentCommandRunner`, `AgentCommandEnvironment`, the output scrubber, and a host-independent `run_command` tool (`root` plus a small `CommandApprovalContext` protocol instead of the `@MainActor` host box).
2. `Umbra`, `UmbraACP` and the CLI link it. Umbra's own `makeClient(for:)` becomes a thin call into the factory. AgentEval does not link it (it must not pull in the app); it gets its own Anthropic and Meta cases from the shared AgentKit clients, or links the factory if that stays dependency-light.
3. No behaviour change in the app; the existing agent tests must pass untouched.

**Phase 2: `umbra-agent` executable (new target in `Umbra/Package.swift`).**
1. `umbra-agent run "prompt"` with `--provider`, `--model`, `--mode plan|accept-edits|auto`, `--max-iterations`, `--cwd`, `--output text|json|stream-json`, `--resume <session>`.
2. Non-interactive rule: configuration is `approval: .askForCommands`, and every approval, question and plan decision is answered with a refusal and a note (the same pattern `runChild` uses today), unless `--mode auto` or an allow rule in the project's permission files covers it. Nothing is ever auto-approved because there is no TTY.
3. Keys come from the environment (`ANTHROPIC_API_KEY` and similar) or Umbra's Keychain items, never from a command-line argument.
4. Exit codes: 0 finished, 1 error, 2 stopped by a budget, 3 an approval was refused. `json` output has a documented, stable shape.
5. Sessions are saved through `SessionStore`, so a CI run opens in AI mode afterwards.
6. Project instructions, memory, skills, commands, agent definitions and MCP config load as in the app (MCP project servers require `--allow-mcp`, standing in for the consent sheet).

**Phase 3: bring `UmbraACP` to parity with the library.** All providers; permission rules; command tools, with each approval sent to the ACP client as `session/request_permission`; MCP behind the same consent rule as the CLI.

## Rules to keep

- AgentKit stays Foundation-only; the CLI and `UmbraACP` are hosts, like Umbra.
- The CLI makes network calls only to the provider the user named.
- `json` output is a contract: version it (`"schema": 1`).
- Sandbox: a CLI run uses the same `IDEAgentSandbox` option as the app, off by default.

## Tests

- `UmbraTests` for the moved pieces run unchanged against `UmbraAgentSupport`.
- CLI: argument parsing; a run against `MockLLMClient` exits 0 with the expected JSON; an approval in a non-interactive run is refused and the exit code is 3; a budget stop exits 2.
- `UmbraACP`: a command approval round trip through `session/request_permission` (phase 3).

## Done when

`umbra-agent run "add a unit test for X" --mode accept-edits --output json` edits files in a scratch repository and exits 0; the same prompt that needs a command, without `--mode auto`, exits 3 with the refused command in the JSON; the chat shows up in the app's history.

## Size

Phase 1: M (mostly moving files and one protocol). Phase 2: M. Phase 3: M.

## Open questions

- Is a separate `umbra-agent` product wanted, or a hidden `--agent` mode of the app binary? A separate executable avoids loading AppKit.
- Should AgentEval share the provider factory, or keep its own so it never links the app package?
