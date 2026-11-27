# Gradle test event protocol

## Version 1

The listener writes a UTF-8 JSON object followed by LF per record in `events.jsonl`. Every record carries a version, session UUID, byte-position sequence number, epoch milliseconds, event kind and canonical build root. A shared writer lock serializes writes across listeners and included builds inside the daemon. Optional fields include module path, Gradle task path, node UUID, parent UUID, name, JVM class, published method, outcome, duration, task disposition, report path and exception details.

| Record | Evidence |
| --- | --- |
| `executionStarted`, `executionFinished` | Settings-evaluated and build-finished callbacks within the instrumented build. |
| `taskStarted`, `taskFinished` | Task graph callbacks and Gradle task state. |
| `suiteStarted`, `suiteFinished` | Suite descriptors, including executor and task-level suites when Gradle publishes them. |
| `testStarted`, `testFinished` | Occurrence IDs assigned using Java object identity. Class and method metadata are separate fields. |
| `output` | Destination, offset and length in `test-output.raw`. Uses the verified descriptor, then its ancestor or task. |

Exceptions carry a type, message, stack trace and expected and actual strings when the throwable exposes structured values. The UI joins parent links by ID even if a parent record arrives later. A repeated sequence is idempotent. Terminal states survive a late start. The consumer records undecodable, incomplete and foreign records as journal issues.

Cancellation is established by the Gradle client outcome. The session seals remaining tests as cancelled after explicit Stop, aborted when task exception evidence establishes a worker failure, or unknown otherwise. A real Gradle 9.9.2 fixture produced synthetic skipped finishes during teardown. The session uses cancellation time and task-level process failure evidence to reclassify affected completions. The Gradle exit code belongs to the invocation. No synthetic per-test passes are inferred from a successful exit.

Explicit configuration-cache launches omit the listeners. The runner considers report XML only when the task and changed file can be attributed. Those rows are identified as report-derived. Included build results retain their own canonical root. A result's display name does not become an invocation ID or automatically become a retry selector. [Gradle configuration cache](https://docs.gradle.org/current/userguide/configuration_cache_adoption.html)
