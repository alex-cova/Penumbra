# Test strategy

## Deterministic tests

```sh
swift test --filter 'GradleNativeRunner|GradleOutputLineSplitter|GradleCommandRunner|GradleProblemMatcher|GradleTestEventParser|JUnitXMLReportParser'
swift test --package-path Packages/SubprocessKit
swift test --package-path Umbra --filter 'IDEGradle|IDETestResults|IDEProjectConsole'
```

The core target exercises JSON decoding, duplicate sequences, out-of-order terminal transitions, cancellation, counters, UTF-8 splitting, oversized lines, stream-tagged page reads, raw export and search, stale and ambiguous XML, Kotlin declarations, task-local retry planning and restart recovery. The subprocess suite injects sink failure. The Umbra suite checks the visible Stop transition and the separate reservation through teardown. The existing parser and console assertions remain.

## Real Gradle fixtures

```sh
python3 Scripts/gradle-test-runner-fixture.py \
  --gradle /path/to/gradle/bin/gradle \
  --java-home /path/to/jdk \
  --root /tmp/new-umbra-gradle-fixture
```

The runner uses locally cached JUnit artifacts listed in the script and an isolated Gradle home. It runs the production listener source against duplicate classes in multiple modules, an included build, parallel workers and a JVM Test Suite. It verifies executed retries and report materialization after configuration-cache reuse. The first invocation starts a cold daemon and subsequent invocations reuse it. Add `--edge-cases` to exercise a worker exit, Gradle build-cache restoration and a client cancellation followed by another run.

## GUI and release acceptance

Use a release app and an otherwise idle macOS session for the three-process comparison. Measure Umbra, Gradle client and daemon, and test workers separately. Record before and after Instruments runs for all input sizes. Exercise live search, scrolling, selection, keyboard navigation, expected and actual values, source links, history restart, Stop and VoiceOver. Use the same project, JDK and pinned Gradle distribution for each comparison. Record release process footprints and signpost latency independently of component benchmarks. The status of those checks is in [Final verification](FINAL_VERIFICATION.md).
