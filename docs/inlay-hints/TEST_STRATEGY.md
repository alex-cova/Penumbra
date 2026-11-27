# Test strategy

Exercise the public text view through geometry tests for stored text, caret affinity, selection and shared rendering. Use native Java fixtures to distinguish proven and ambiguous binding. Fake servers exercise protocol requests and malformed positions independently of installed servers. Keep real servers, GUI smoke testing and Release timing separate from deterministic CI. Compare editor CPU timing and memory on the same fixtures in Release and record actual sample counts.

## Baseline skip reasons

### Root

- 1 × Parity corpus runs only with JAVA_PARITY=1
- 1 × Parity corpus runs only with SWIFT_PARITY=1
- 5 × Runs only with SWIFT_PARITY=1
- 1 × Set JAVA_AUDIT=1 to run the receiver-type audit
- 1 × Set JAVA_DIFFERENTIAL=1 to score gson and jackson-core, cloned into ~/Library/Caches/umbra-differential
- 1 × Set JAVA_DIFFERENTIAL_REPORT=1 to print rank buckets per role (uses JAVA_DIFFERENTIAL_FILES / JAVA_DIFFERENTIAL_POSITIONS overrides)
- 1 × Set JAVA_QUALITY=1 (and JAVA_QUALITY_SET=development|held-out|all) to score completion
- 2 × Set UMBRA_HPROF to a .hprof file to run
- 1 × Spring 6.1.11 jars are not in ~/.m2
- 1 × The coverage tool (JaCoCo 0.8.15) supports up to Java 26, and this project builds for Java 27. Run without coverage, or choose an older Java.
- 1 × The semantic ceiling runs only with SWIFT_PARITY=1
- 1 × jOOL checkout missing
- 1 × mvn is not installed
- 1 × set LARGE_FILE_MEASURE_MB to measure a real open
- 1 × set PENUMBRA_HIGHLIGHT_STRESS=<iterations> to run
- 1 × set SWIFT_INSPECTION_APPLY_FIXES_TO to a copy of the repository
- 1 × set SWIFT_REFACTOR_APPLY_TO to a copy of the repository
- 4 × set UMBRA_PREVIEW_INTEGRATION=1 to run the preview pipeline test

### Umbra

- 1 × /Users/alex/.cargo/bin/rust-analyzer is present but does not run (`--version` failed)
- 2 × Live Codex and Claude Code sessions are paid and contact a model; set UMBRA_LIVE_ACP=1 to run them
- 2 × Requires the window server
- 1 × Set UMBRA_HPROF and UMBRA_HEAP_INDEX_ROOT to run
- 1 × Set UMBRA_JS_DEBUG=1 to run the js-debug session
- 1 × Set UMBRA_LLDB_DAP=1 to run the lldb-dap session
- 1 × Set UMBRA_LLDB_DAP=1 to run the lldb-dap spike
- 1 × Set UMBRA_TEMPLATE_SAMPLES to a directory to write sample projects.
- 16 × Starts the real Kiro, Cursor and Muse CLIs; set UMBRA_LIVE_ACP_NATIVE=1 to run
- 1 × SwiftUI builds its accessibility tree only for a running assistive client; nothing to inspect here
- 1 × needs a window server (UMBRA_UI_TESTS=1)
- 6 × needs the database containers; never on CI
- 1 × set UMBRA_AGENT_MLX_MODEL to run this against an on-device model
- 4 × set UMBRA_AGENT_OLLAMA_MODEL to run this against a real local model
- 1 × set UMBRA_GIT_COST_REPO to run
- 1 × set UMBRA_PACKAGED_APP to a built Umbra.app
- 16 × set UMBRA_PREVIEW_INTEGRATION=1 to run the preview pipeline test
- 1 × set UMBRA_PREVIEW_IOS_PROJECT, _FILE and _TARGET to preview a project of your own
- 1 × set UMBRA_PSQL_DB to a local database to run
- 41 × set UMBRA_UI_TESTS=1 to run tests that need a window server
