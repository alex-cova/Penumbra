import Foundation

/// The init script (`gradle -I <script>`) that makes every `Test` task print one structured marker
/// line per suite/test event, so the IDE can show live progress while Gradle runs. The JUnit XML
/// reports stay authoritative for messages, stack traces and output; markers only carry status
/// and timing.
///
/// Line format (fields separated by `|`):
/// `##umbra-test|<event>|<taskPath>|<className>|<methodName>|<result>|<durationMs>`
/// where `<event>` is `suiteStart`, `suiteEnd`, `testStart` or `testEnd`, `<result>` is
/// `PASSED`/`FAILED`/`SKIPPED` (empty on start events) and `<durationMs>` is empty on start events.
/// Inside a field, `\` is written `\\`, `|` is `\p`, a line feed `\n` and a carriage return `\r`
/// (see ``GradleTestEventParser``).
///
/// Works with `useJUnitPlatform()` and JUnit 4: both report through Gradle's `TestListener`.
public enum GradleTestEventsScript {
    public static let markerPrefix = "##umbra-test|"

    /// A raw Swift string, so the Groovy backslashes below are literal.
    public static let source = #"""
    import org.gradle.api.tasks.testing.Test
    import org.gradle.api.tasks.testing.TestDescriptor
    import org.gradle.api.tasks.testing.TestListener
    import org.gradle.api.tasks.testing.TestResult

    class UmbraTestEventListener implements TestListener {
        final String taskPath

        UmbraTestEventListener(String taskPath) {
            this.taskPath = taskPath
        }

        private static String esc(Object value) {
            if (value == null) { return '' }
            return value.toString()
                .replace('\\', '\\\\')
                .replace('|', '\\p')
                .replace('\n', '\\n')
                .replace('\r', '\\r')
        }

        private void emit(String event, TestDescriptor d, String result, String duration, boolean isTest) {
            String method = isTest ? d.name : ''
            System.out.println('##umbra-test|' + event + '|' + esc(taskPath) + '|' + esc(d.className) + '|' +
                esc(method) + '|' + result + '|' + duration)
        }

        private static String resultName(TestResult r) {
            switch (r.resultType) {
                case TestResult.ResultType.SUCCESS: return 'PASSED'
                case TestResult.ResultType.FAILURE: return 'FAILED'
                default: return 'SKIPPED'
            }
        }

        void beforeSuite(TestDescriptor d) {
            if (d.className != null) { emit('suiteStart', d, '', '', false) }
        }

        void afterSuite(TestDescriptor d, TestResult r) {
            if (d.className != null) {
                emit('suiteEnd', d, resultName(r), String.valueOf(r.endTime - r.startTime), false)
            }
        }

        void beforeTest(TestDescriptor d) {
            emit('testStart', d, '', '', true)
        }

        void afterTest(TestDescriptor d, TestResult r) {
            emit('testEnd', d, resultName(r), String.valueOf(r.endTime - r.startTime), true)
        }
    }

    allprojects { p ->
        p.tasks.withType(Test).configureEach { t ->
            t.addTestListener(new UmbraTestEventListener(t.path))
        }
    }
    """#

    /// Writes the script into `directory` (created if needed) and returns its URL, ready for `-I`.
    @discardableResult
    public static func write(toDirectory directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("umbra-test-events.gradle")
        let data = Data(source.utf8)
        if (try? Data(contentsOf: url)) != data {
            try data.write(to: url, options: .atomic)
        }
        return url
    }
}
