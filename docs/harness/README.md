# Harness gap plans

Eight plans for bringing Umbra's agent harness level with Claude Code and OpenCode and for making better use of local models. Written 2026-10-26 and checked against the code the same day. Background and what is already built: `docs/harness/BUILT.md` and the `CLAUDE.md` files under `Packages/AgentKit` and `Umbra/Sources/Umbra/Agent`.

| # | Plan | Status | Size |
|---|---|---|---|
| 1 | [`agent-harness-1.md`](agent-harness-1.md) MCP over HTTP, OAuth, prompts and resources | open | L |
| 2 | [`agent-harness-2.md`](agent-harness-2.md) Subagents: approval routing, per-agent model, cards, persistence | open (phase 0 is a bug fix) | M to L |
| 3 | [`agent-harness-3.md`](agent-harness-3.md) User-configurable hooks | decision needed | M |
| 4 | [`agent-harness-4.md`](agent-harness-4.md) Image input | decision needed | L |
| 5 | [`agent-harness-5.md`](agent-harness-5.md) Git tools and worktrees | open | S to L |
| 6 | [`agent-harness-6.md`](agent-harness-6.md) Shared agent library, `umbra-agent` CLI, `UmbraACP` parity | open | M to L |
| 7 | [`agent-harness-7.md`](agent-harness-7.md) Smaller items: measurement, export, LSP tools, `/loop` | open | S each |
| 8 | [`agent-harness-8.md`](agent-harness-8.md) Local models as helpers for hosted ones: helper model, `model:` per agent, capability gate, accounting | open | S to M |

## Suggested order

Plans 1, 2 and 3 are what a Claude Code user misses first and extend code that exists. Then 6, which also makes the harness testable from the command line. Plan 5's first phase (git tools) is small and fixes commits under the command sandbox; its worktrees are large. Plans 3 and 4 need a decision from the owner first.

## Dependencies between plans

- **2:** approval routing (phase 1) comes before giving children command tools.
- **6 before 3, if both are planned.** The shared library gives hooks, permission files and the command runner one home for the app, `UmbraACP` and the CLI.
- **8 needs 2 phase 2** (per-agent model) and is measured with 7 item 1 (saved AgentEval results).
- **5:** the per-chat root (phase 3) comes before worktrees (phases 4 and 5).
- **7 item 1 needs 6 phase 1** for Anthropic and Meta in AgentEval.
- **3 and 7 (plugins) contradict** the "Not planned" line in `docs/harness/BUILT.md`; **4** touches its "image pruning (AI mode is text-only)" note. Update that line when one of them is approved.

## Things found while checking the code

Fix these regardless of which plan goes ahead:
- A subagent's edits skip the cross-chat file-claims gate (`agent-harness-2.md`, phase 0).
- `git commit` through `run_command` fails with the command sandbox on, because `.git` is read-only (`agent-harness-5.md`).
- Navigation tool messages and `Umbra/Sources/Umbra/Agent/CLAUDE.md` still describe the navigator as Java-only (`agent-harness-7.md`, item 3).
- Provider construction is duplicated in Umbra, `UmbraACP` and AgentEval (`agent-harness-6.md`).
- AgentEval results are not saved anywhere, so claims about measurements cannot be checked (`agent-harness-7.md`, item 1).

## Each plan has the same sections

Status, what exists today (with files and symbols), gap, what Claude Code and OpenCode do, proposal in phases, rules to keep, tests, done when, size, open questions. Code is referenced by file and symbol name, not line number, because lines drift.
