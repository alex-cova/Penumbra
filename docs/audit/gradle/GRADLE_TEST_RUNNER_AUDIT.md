# Gradle test runner audit

## Launch path

A gutter action, Run in Context, Test action or saved Java configuration enters `IDEJavaRunProvider`. The provider resolves the selected test scope against `JavaTestRunner` and the cached Gradle model. The project system saves buffers, prompts for project trust and resolves a compatible JDK. `GradleCommandRunner` rechecks trust and prefers the project's wrapper. It supports invoking a non-executable wrapper through `/bin/sh` and falls back to a Gradle launcher on the login-shell PATH.

Model extraction and dependency diagrams use their existing init scripts and structured model files. A former project sync used captured text for JDK fallback and error summaries. Interactive model launches now keep bounded diagnostic excerpts in addition to the disk log. The public command runner continues to support full capture for clients that request a result without a disk log.

Saved test configurations supply Gradle arguments, environment overrides, system properties, working directory and JDK selection. Existing launch preparation still runs configured before-launch tasks on initial launches. The listener leaves the Gradle task graph, framework and worker configuration in the project's control. The debugger uses the existing JDWP adapter. Coverage and profiling keep their existing Gradle instrumentation and use the test session ID to match completion.

## Reproduced baseline problems

| Problem | Reproduction | Correction |
| --- | --- | --- |
| Late cancellation callback | Cancel a sleeping wrapper, then request a second task before the first completes. | Workspace remains reserved until the client returns, both pipes drain and the session settles. |
| Cross-module selection | Run identical class names from two tasks and fail different methods in each. | Group selectors by canonical build and task. Issue separate task invocations for granular retries. |
| Stale XML | Leave a previous TEST XML file in the report directory before starting a task. | Require a unique task owner, observed task activity and a changed file within the run window. |
| Oversized line | Feed a line larger than a pipe read, splitting multibyte UTF-8 across reads. | Keep diagnostic segments bounded and preserve the original bytes in the log. |
| Log memory growth | Exercise capture, decoding and the 10,000-line console using fixed-size workload lines. | Interactive tasks stream to disk and render a bounded viewport. |
| No live result producer | The console-marker parser and script had unit tests but the dedicated test path never called them. | Attach the session journal init script to cache-off test invocations. |

The before and after component measurements are in [Performance baseline](PERFORMANCE_BASELINE.md). The marker parser and writer remain available to existing API clients and their tests. Umbra uses the sidecar on the dedicated Gradle test path.

## References

- [Gradle test execution and filters](https://docs.gradle.org/current/userguide/java_testing.html)
- [Gradle test descriptor API](https://docs.gradle.org/current/javadoc/org/gradle/api/tasks/testing/TestDescriptor.html)
- [IntelliJ Gradle testing](https://www.jetbrains.com/help/idea/work-with-tests-in-gradle.html)
