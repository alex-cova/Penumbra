#!/usr/bin/env python3
"""Performance regression gate over PerfHarness (audit finding F06).

Subcommands
  run     Run the harness scenarios (Release) and write a results JSON.
  check   Compare a results JSON against absolute budgets and, optionally, a results JSON from
          the parent commit measured back to back in the same session.
  record  Turn a results JSON into a budgets file (absolute backstop).

Why two layers: timings drift up to ~2x between days on the same binary
(docs/PERFORMANCE_RULES.md section 9), so a checked-in number alone cannot catch a 2x regression.
The pairwise check (HEAD vs parent, same machine, same session, medians of repeated runs) is the
real gate; the checked-in budgets only catch order-of-magnitude regressions and counter changes.

Counters (shiftVisits, extracts, live handles...) are deterministic and are held tight.
Run with the display awake: `caffeinate -u -d -i -s Scripts/perf-gate.py run ...`.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_BUDGETS = ROOT / "Scripts" / "perf-budgets.json"

# Scenario name -> harness argument list ({java} is replaced by a generated fixture path).
SCENARIOS: dict[str, list[str]] = {
    "enter-session-20k": ["enter-session", "synthetic", "--lines", "20000"],
    "enter-session-120k": ["enter-session", "synthetic", "--lines", "120000"],
    "keystroke-budget": ["keystroke-budget", "{java}", "--lang", "java", "--samples", "30"],
}

# Rows whose `seconds` column is a latency worth gating, per scenario prefix.
TIME_METRICS = re.compile(r"^(enter_|scroll_page|scroll_step|select_all_occurrences|keystroke_until_observer)")
# Rows whose `seconds` column is really a count (the harness prints counters there as 0.000000).
COUNT_ROWS = re.compile(r"^(keystroke_waits|keystroke_sync_highlight_lines|keystroke_next_drawable)")
COUNTER_KEYS = ("shiftVisits", "extracts", "decorations", "live")

# Tolerances.
PAIRWISE_TIME_RATIO = 1.5      # HEAD median may be at most 1.5x parent median
PAIRWISE_NOISE_FLOOR = 0.00005  # ...and must also exceed parent by 50 µs (keystroke p95 is ~0.1 ms)
PAIRWISE_COUNTER_RATIO = 1.10
BUDGET_TIME_FACTOR = 3.0       # absolute backstop = recorded * 3 (>= the documented 2x drift)
BUDGET_TIME_FLOOR = 0.002
BUDGET_COUNTER_FACTOR = 1.5


def generate_java_fixture(directory: Path) -> Path:
    lines = ["package demo;", "public class Big {"]
    for i in range(8000):
        lines.append(f"    public int method{i}(int a, String b) {{ return a + b.length() + {i}; }}")
    lines.append("}")
    path = directory / "Big.java"
    path.write_text("\n".join(lines) + "\n")
    return path


def parse_csv(scenario: str, text: str) -> dict[str, float]:
    """Harness CSV (metric,file,size_bytes,seconds,extra) -> flat {key: value}."""
    out: dict[str, float] = {}
    for line in text.splitlines():
        parts = line.split(",", 4)
        if len(parts) < 4 or parts[0] == "metric":
            continue
        metric = parts[0]
        try:
            seconds = float(parts[3])
        except ValueError:
            continue
        extra = parts[4] if len(parts) > 4 else ""
        if COUNT_ROWS.match(metric):
            out[f"{scenario}/{metric}#count"] = seconds
        elif TIME_METRICS.match(metric):
            out[f"{scenario}/{metric}"] = seconds
        if metric.startswith(("enter_", "handles_")):
            for key in COUNTER_KEYS:
                m = re.search(rf"\b{key}=(\d+)", extra)
                if m:
                    out[f"{scenario}/{metric}#{key}"] = float(m.group(1))
    return out


def run_scenarios(harness: list[str], repeats: int, only: list[str] | None, source: Path) -> dict[str, float]:
    samples: dict[str, list[float]] = {}
    with tempfile.TemporaryDirectory() as tmp:
        java = generate_java_fixture(Path(tmp))
        for name, args in SCENARIOS.items():
            if only and name not in only:
                continue
            argv = harness + [a.replace("{java}", str(java)) for a in args]
            for attempt in range(repeats):
                print(f"[perf-gate] {name} run {attempt + 1}/{repeats}", file=sys.stderr)
                proc = subprocess.run(argv, capture_output=True, text=True, cwd=source)
                if proc.returncode != 0:
                    sys.stderr.write(proc.stderr[-2000:])
                    raise SystemExit(f"harness failed for {name} (exit {proc.returncode})")
                for key, value in parse_csv(name, proc.stdout).items():
                    samples.setdefault(key, []).append(value)
    # Median across repeats: timings are noisy, counters are identical anyway.
    return {key: statistics.median(values) for key, values in sorted(samples.items())}


def is_counter(key: str) -> bool:
    return "#" in key


def check(results: dict[str, float], budgets: dict[str, float], parent: dict[str, float] | None) -> list[str]:
    failures: list[str] = []
    for key, value in results.items():
        if key in budgets and value > budgets[key]:
            failures.append(f"BUDGET   {key}: {value:.6g} > budget {budgets[key]:.6g}")
        if parent and key in parent:
            base = parent[key]
            if is_counter(key):
                if value > base * PAIRWISE_COUNTER_RATIO + 1:
                    failures.append(f"COUNTER  {key}: {value:.6g} vs parent {base:.6g}")
            elif value > base * PAIRWISE_TIME_RATIO and value - base > PAIRWISE_NOISE_FLOOR:
                failures.append(f"REGRESS  {key}: {value * 1000:.3f} ms vs parent {base * 1000:.3f} ms "
                                f"({value / base:.2f}x)")
    missing = [k for k in budgets if k not in results]
    if missing and not parent:
        # A vanished metric usually means the harness output changed; do not let the gate go blind.
        failures.append(f"MISSING  {len(missing)} budgeted metrics absent from results, e.g. {missing[0]}")
    return failures


def make_budgets(results: dict[str, float]) -> dict[str, float]:
    budgets: dict[str, float] = {}
    for key, value in results.items():
        if is_counter(key):
            budgets[key] = round(value * BUDGET_COUNTER_FACTOR + 2, 3)
        else:
            budgets[key] = round(max(value * BUDGET_TIME_FACTOR, BUDGET_TIME_FLOOR), 6)
    return budgets


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    run = sub.add_parser("run")
    run.add_argument("--out", required=True, type=Path)
    run.add_argument("--repeats", type=int, default=3)
    run.add_argument("--scenario", action="append", choices=list(SCENARIOS))
    run.add_argument("--build-path", default=None, help="SwiftPM --build-path (one per commit when comparing)")
    run.add_argument("--source", type=Path, default=ROOT,
                     help="Checkout to build and measure (default: the checkout holding this script)")
    run.add_argument("--harness", default=None,
                     help="Prebuilt PerfHarness binary; default is `swift run -c release PerfHarness`")

    chk = sub.add_parser("check")
    chk.add_argument("results", type=Path)
    chk.add_argument("--budgets", type=Path, default=DEFAULT_BUDGETS)
    chk.add_argument("--parent", type=Path, help="Results JSON measured on the parent commit, same session")

    rec = sub.add_parser("record")
    rec.add_argument("results", type=Path)
    rec.add_argument("--budgets", type=Path, default=DEFAULT_BUDGETS)

    args = parser.parse_args()

    if args.command == "run":
        if args.harness:
            harness = [args.harness]
        else:
            harness = ["swift", "run", "-c", "release"]
            if args.build_path:
                harness += ["--build-path", args.build_path]
            harness += ["PerfHarness"]
        results = run_scenarios(harness, args.repeats, args.scenario, args.source)
        args.out.write_text(json.dumps(results, indent=2, sort_keys=True) + "\n")
        print(f"[perf-gate] wrote {len(results)} metrics to {args.out}", file=sys.stderr)
        return 0

    if args.command == "record":
        results = json.loads(args.results.read_text())
        args.budgets.write_text(json.dumps(make_budgets(results), indent=2, sort_keys=True) + "\n")
        print(f"[perf-gate] recorded {len(results)} budgets to {args.budgets}", file=sys.stderr)
        return 0

    results = json.loads(args.results.read_text())
    budgets = json.loads(args.budgets.read_text()) if args.budgets.exists() else {}
    parent = json.loads(args.parent.read_text()) if args.parent else None
    failures = check(results, budgets, parent)
    for line in failures:
        print(line)
    if failures:
        print(f"[perf-gate] FAILED: {len(failures)} regression(s)")
        return 1
    print(f"[perf-gate] OK: {len(results)} metrics within budget"
          + (" and within pairwise tolerance of the parent" if parent else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
