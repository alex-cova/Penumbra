# AgentEval results

Saved `--json` output from `swift run AgentEval run`, one file per measurement:
`<date>-<change>.json` (for example `2026-10-26-tolerant-arguments.json`).

Each file that lands here gets one summary line — provider, model, trials,
passes — in the doc that motivated the change (for example the tolerant-arguments
line in `docs/harness/agent-harness-7.md` §1; an earlier `BUILT.md` was deleted), so a claim about
a measurement can be checked.

**Invalid:** `2026-11-02-tolerant-arguments.json` — 20 of its 21 failures are `Could not connect to localhost`
(Ollama was down, the trials never ran). Kept for the record; not a baseline. Check a result's `ending` values
for `failed: Could not connect` before comparing it with another run.
**Long runs:** keep the Mac on AC power (`caffeinate -s` holds only on AC); a run that hibernates records the sleep in
`seconds`.
