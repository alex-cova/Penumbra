# GitHub performance budget

These are initial engineering budgets. Baseline and after-change results must use the same machine, toolchain, build configuration and dataset.

| Workload | Initial gate |
| --- | --- |
| Editor typing, selection and scrolling | Zero new GitHub requests, Keychain lookups, Git subprocesses, buffer materializations or GitHub model publications per edit/caret event. Apply paired p95 around editor interactions with baseline variability recorded. Investigate a sustained change greater than 5% or 0.25 ms, whichever is larger. |
| Workspace without an eligible remote or signed-in account | Zero outbound GitHub requests and zero polling. Share the existing repository discovery. Read remote details once per relevant root/config generation. |
| Repository pane | First eligible view renders local loading/cached state within 100 ms p95 on the baseline Mac. Network completion is measured separately. Coalesce identical reads by authority/account/representation. Start with one concurrent request per account and bound queued work. |
| Account and app startup | Zero GitHub network while no active feature needs it. Do not block app or editor startup on Keychain. |
| Memory | Start with a 16 MiB total repository metadata/list cache and a 2 MiB cap for individual JSON responses. Count decoded overhead when profiling. Load one visible diff or log on demand and apply independent size limits. |
| Revalidation and polling | Conditional requests. No background timers for closed surfaces in the foundation. For Actions and notifications, honor endpoint and rate-limit timing and stop polling inactive surfaces. |
| Cancellation | No further UI publications from a detached workspace generation. Release subscriber, queued work and response storage promptly. Verify with a deterministic suspended-response test and Instruments for actual networking. |

Use `InteractivePathTests`, `IDEHostEditCostTests`, and `Tools/PerfHarness` keystroke/scroll profiles. For runtime phases also use Time Profiler, Allocations and URLSession metrics with a canned workload covering 20 remotes, 5 accounts, a 100-row list, and a large diff. Record p50/p95, peak/incremental resident memory, cache occupancy, requests, subprocess counts and teardown behavior. Check unrelated windows and change markers remain responsive during refresh. Historical numbers are in `docs/EDITOR_PERFORMANCE_REPORT.md`. Current runs and known gaps are in [progress](PROGRESS.md).
