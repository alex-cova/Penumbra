# AgentEval results

Saved `--json` output from `swift run AgentEval run`, one file per measurement:
`<date>-<change>.json` (for example `2026-10-26-tolerant-arguments.json`).

Each file that lands here gets one summary line — provider, model, trials,
passes — in the doc that motivated the change (for example the tolerant-arguments
line in `docs/harness/BUILT.md`), so a claim about a measurement can be checked.
