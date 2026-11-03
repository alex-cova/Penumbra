# Harness gap 6: headless use and one shared agent library

Part of the series `agent-harness-1.md` to `agent-harness-7.md` (index: `README.md`). Checked against the code on 2026-10-26; implemented 2026-11-02.

**Status:** implemented (phases 1–3). Phase 1 (the shared library) is the enabler for the CLI and for `agent-harness-3.md`.

## What exists today

- **`UmbraACP` is an ACP agent (server) on stdio** (`Umbra/Sources/UmbraACP/main.swift`), wrapping `AgentSession`s in AgentKit's `ACPAgentEndpoint`. It serves read and edit tools, the shared host-independent `run_command` (`UmbraAgentRunCommandTool`), `todo`, `ask_user`, `exit_plan_mode`, Accept Edits mode and a `SessionStore`. Config comes from flags, then `UMBRA_ACP_*` environment variables, then Umbra's UserDefaults; the key from the environment or Umbra's Keychain. All providers go through the shared `UmbraAgentProviderFactory`; permission rules load from the same files as the app; command approvals reach the ACP client as `session/request_permission`; project MCP servers start behind `--allow-mcp`/`UMBRA_ACP_ALLOW_MCP=1`; `--sandbox` reuses the app's Seatbelt profile. (An earlier version of this doc said Umbra was only an ACP client; that is wrong.)
- **The ACP client side** is `Umbra/Sources/Umbra/Agent/ACP` (`IDEACPDefinition`, `IDEACPTransport`, `IDEACPHostServices` with `fs/*` and `terminal/*`): Umbra drives external agents.
- **`Tools/AgentEval`** is an evaluator (`list`, `validate`, `run`; `--trials`, `--jobs`, `--json`, `--transcripts`). It builds its session in `TrialRunner` with `DiskAgentWorkspace`, `ReadOnlyTools` + `EditingTools` + a `run_tests` bound to the task check, and `.approveAll`. Providers: ollama, openai, chat, anthropic, meta, mlx, apple, apple-pcc.
- **Provider construction:** headless hosts (`UmbraACP`, `umbra-agent`) share `UmbraAgentProviderFactory` in `UmbraAgentSupport`. Deliberate deviation from the proposal's "thin call" item: the app's interactive `IDEAgentClientFactory` keeps its own construction because it resolves from a settings snapshot (cached Ollama/MLX catalogs, consent and key state, helper-model gating) — delegating to the factory would add live catalog fetches per call and change its errors, breaking the no-behaviour-change rule. AgentEval's `Providers` (which must not link the app package) keeps its own, with Anthropic and Meta cases from the shared AgentKit clients.
- **`Umbra/Package.swift` has a library target `UmbraAgentSupport`** plus executables (`Umbra`, `UmbraACP`, `UmbraAgent` product `umbra-agent`) and `UmbraTests`. The host-independent pieces moved into the library: `IDEAgentPermissionFiles`, `AgentCommandRunner`/`AgentCommandEnvironment`, `IDEAgentOutputScrubber`, `IDEAgentSandbox`, `IDEAgentKeyStore` (all `public`; `Umbra` re-exports them so existing code and tests resolve unchanged), plus the provider factory, the host-independent `run_command` (`UmbraAgentCommandHost` protocol instead of the `@MainActor` host box — `IDERunCommandTool` itself stays in the app with its Gradle/Maven runners), the headless run driver, and CLI parsing. AgentKit stays Foundation-only; the CLI and `UmbraACP` are hosts, like Umbra.
- **The CLI is `umbra-agent run "prompt"`** (`Umbra/Sources/UmbraAgent/main.swift`, product `umbra-agent`): `--provider`, `--model`, `--base-url`, `--mode plan|accept-edits|auto|manual`, `--max-iterations`, `--max-run-tokens`, `--max-run-seconds`, `--cwd`, `--output text|json|stream-json`, `--resume`, `--allow-mcp`, `--sandbox`, repeatable `--env KEY=VALUE`. Non-interactive rule as proposed (refuse every approval/question/plan with a note; exit 3). Sessions save through `SessionStore` into the app's directory. Project instructions (`AGENTS.md`/`CLAUDE.md`, `~/.claude/CLAUDE.md`), memory, project skills/commands, permission files and (behind the flag) project MCP servers load headlessly.
- **`UmbraMain` still only handles the git password prompt** (`GIT_ASKPASS`) before starting the app.
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

- `UmbraTests` for the moved pieces run unchanged against `UmbraAgentSupport` (verified: 111 tests across permission files, command runner/tools, scrubber, permissions, providers, approval flow and ACP client pass untouched).
- CLI (`Umbra/Tests/UmbraTests/UmbraAgentCLITests.swift`): argument parsing; a run against `MockLLMClient` exits 0 with the expected JSON (`"schema": 1`); a headless file edit lands on disk and exits 0; an approval in a non-interactive run is refused and the exit code is 3 with the refused command in the JSON; an iteration-cap stop exits 2; the factory builds Anthropic and Meta clients.
- `UmbraACP` (`Umbra/Tests/UmbraTests/UmbraACPAgentParityTests.swift`): a command approval round trip through `session/request_permission` with the real `UmbraAgentRunCommandTool` (approve runs it, deny stops it).

## Done when

`umbra-agent run "add a unit test for X" --mode accept-edits --output json` edits files in a scratch repository and exits 0 (proven at the driver level with `MockLLMClient`; live-model runs additionally need a key and network); the same prompt that needs a command, without `--mode auto`, exits 3 with the refused command in the JSON; the chat shows up in the app's history (sessions save into the app's `SessionStore` directory; verified a snapshot lands per run).

## Size

Phase 1: M (mostly moving files and one protocol). Phase 2: M. Phase 3: M.

## Open questions

- Is a separate `umbra-agent` product wanted, or a hidden `--agent` mode of the app binary? A separate executable avoids loading AppKit.
- Should AgentEval share the provider factory, or keep its own so it never links the app package?
