# Gradle test runner implementation

| Phase | Implemented | Remaining acceptance work |
| --- | --- | --- |
| Audit | Traced trust, model, launch, diagnostics, reporting and cancellation. Reproduced stale report, cross-module retry, stale completion and long lines. | Capture the pre-change and post-change release app under Instruments. |
| Console | Streaming subprocess sink, committed stream-tagged index, bounded diagnostics and viewport, export and search. | Continuous byte-addressed scrolling, stable selections across pages, persisted ANSI checkpoints and GUI measurements. |
| Events | Versioned listener sidecar and actor-based ingestion with occurrence IDs, batched deltas, terminal states and XML fallback. | Expand worker-crash and infrastructure error classification. Verify more framework combinations and report enrichment. |
| Test Results | Native list in the existing resizable split, counts, failure navigation, source links, inspection and reports. History restores journals and logs. | Profile and validate large live trees, accessibility and retained scroll position under heavy event traffic. |
| Retry | Encrypted launch snapshots, verified task-scoped rerun on three Gradle releases, task-local granular retries and broader-scope confirmation. | Replay debugger, coverage and before-launch sessions. Verify included-build retry routing and exact invocation selectors. |
| Editor | Java and conservative Kotlin/JVM discovery, existing gutter actions, past-result lookup and module-first source navigation. | Scope result decorations to the affected editor markers. Verify editor, debugger and JaCoCo flows end to end. |

The subsystem remains within JavaIntelligence, SubprocessKit and the existing Umbra Gradle project, run and Test Results components. Test and build fixture scripts run in scratch directories. The Gradle fixture runner takes a launcher, JDK and local pinned dependency jars.
