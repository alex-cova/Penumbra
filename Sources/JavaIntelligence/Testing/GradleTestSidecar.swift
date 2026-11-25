import Foundation

public enum GradleTestSidecar {
    /// Gradle's final explicit setting wins. Cache-on launches keep their arguments and use reports.
    public static func configurationCacheEnabled(arguments: [String]) -> Bool {
        var enabled = false
        for argument in arguments {
            switch argument {
            case "--configuration-cache", "-Dorg.gradle.configuration-cache=true": enabled = true
            case "--no-configuration-cache", "-Dorg.gradle.configuration-cache=false": enabled = false
            default: break
            }
        }
        return enabled
    }

    public static func arguments(for session: GradleTestSession) throws -> [String] {
        let script = session.directory.appendingPathComponent("test-events.init.gradle")
        try Data(source.utf8).write(to: script, options: .atomic)
        return ["--init-script", script.path, "-Dumbra.test.session=\(session.id.uuidString)",
                "-Dumbra.test.directory=\(session.directory.path)"]
    }

    static let source = #"""
    import groovy.json.JsonOutput
    import org.gradle.api.tasks.testing.Test

    class UmbraTestJournal {
        final File events
        final File output
        final String session
        final Object lock

        UmbraTestJournal(File directory, String session) {
            events = new File(directory, 'events.jsonl')
            output = new File(directory, 'test-output.raw')
            this.session = session
            lock = ("umbra-test-" + session).intern()
        }

        void emit(Map fields, byte[] bytes = null, String stream = null) {
            synchronized (lock) {
                if (bytes != null) {
                    fields.output = [offset: output.length(), length: bytes.length, stream: stream]
                    new FileOutputStream(output, true).withCloseable { it.write(bytes) }
                }
                Map record = [version: 1, sessionID: session, sequence: events.length(),
                              timestamp: System.currentTimeMillis()] + fields
                events.append(JsonOutput.toJson(record) + '\n', 'UTF-8')
            }
        }

        static Map failure(Throwable error) {
            if (error == null) { return null }
            Throwable cause = error
            for (int depth = 0; depth < 16 && cause.cause != null && cause.cause != cause; depth++) {
                cause = cause.cause
            }
            StringWriter writer = new StringWriter()
            error.printStackTrace(new PrintWriter(writer))
            def detail = [type: cause.class.name, message: error.message?.take(8192), stackTrace: writer.toString().take(32768)]
            if (cause.metaClass.respondsTo(cause, 'getExpected') && cause.metaClass.respondsTo(cause, 'getActual')) {
                def expected = cause.expected
                def actual = cause.actual
                if (expected?.metaClass?.respondsTo(expected, 'getStringRepresentation')) { expected = expected.stringRepresentation }
                if (actual?.metaClass?.respondsTo(actual, 'getStringRepresentation')) { actual = actual.stringRepresentation }
                detail.expected = expected?.toString()?.take(8192)
                detail.actual = actual?.toString()?.take(8192)
            }
            return detail
        }
    }

    def directory = new File(System.getProperty('umbra.test.directory'))
    def session = System.getProperty('umbra.test.session')
    def journal = new UmbraTestJournal(directory, session)
    def build = null
    def buildNode = UUID.randomUUID().toString()
    def taskNodes = [:]
    gradle.settingsEvaluated { settings ->
        build = settings.rootDir.canonicalPath
        journal.emit(kind: 'executionStarted', build: build, nodeID: buildNode, name: settings.rootProject.name)
    }
    def taskNode = { task ->
        synchronized (taskNodes) {
            taskNodes.computeIfAbsent(task.path) { UUID.randomUUID().toString() }
        }
    }
    gradle.taskGraph.beforeTask { task ->
        journal.emit(kind: 'taskStarted', build: build, module: task.project.path, task: task.path,
                     nodeID: taskNode(task), parentID: buildNode, name: task.name)
    }
    gradle.taskGraph.afterTask { task, state ->
        def disposition = state.skipMessage ?: (state.upToDate ? 'upToDate' : (state.didWork ? 'worked' : 'noWork'))
        def report = task instanceof Test && task.reports.html.required.getOrElse(false) ?
            new File(task.reports.html.outputLocation.get().asFile, 'index.html').absolutePath : null
        journal.emit(kind: 'taskFinished', build: build, module: task.project.path, task: task.path,
                     nodeID: taskNode(task), parentID: buildNode, name: task.name, disposition: disposition, report: report,
                     outcome: state.failure != null ? 'failed' : (state.skipped ? 'skipped' : 'passed'),
                     failure: UmbraTestJournal.failure(state.failure))
    }
    gradle.buildFinished { result ->
        if (build != null) {
            journal.emit(kind: 'executionFinished', build: build, nodeID: buildNode,
                         outcome: result.failure == null ? 'passed' : 'failed', failure: UmbraTestJournal.failure(result.failure))
        }
    }
    allprojects { project ->
        tasks.withType(Test).configureEach { task ->
            def occurrences = new IdentityHashMap()
            def emit = { String kind, descriptor, result ->
                synchronized (occurrences) {
                    def node = occurrences.computeIfAbsent(descriptor) { UUID.randomUUID().toString() }
                    def parent = descriptor.parent == null ? taskNode(task) :
                        occurrences.computeIfAbsent(descriptor.parent) { UUID.randomUUID().toString() }
                    def method = null
                    if (descriptor.metaClass.respondsTo(descriptor, 'getSource')) {
                        def source = descriptor.source
                        if (source != null && source.metaClass.respondsTo(source, 'getMethodName')) {
                            method = source.methodName
                        }
                    }
                    def fields = [kind: kind, build: build, module: project.path, task: task.path,
                                  nodeID: node, parentID: parent, name: descriptor.name?.take(4096),
                                  className: descriptor.className, methodName: method]
                    if (result != null) {
                        fields.outcome = [SUCCESS: 'passed', FAILURE: 'failed', SKIPPED: 'skipped'][result.resultType.name()]
                        fields.durationMs = Math.max(0L, result.endTime - result.startTime)
                        if (!result.exceptions.empty) { fields.failure = UmbraTestJournal.failure(result.exceptions.first()) }
                    }
                    journal.emit(fields)
                    // Parent identity is needed for late worker output. Keep suite IDs until task teardown.
                    if (kind == 'testFinished') { occurrences.remove(descriptor) }
                }
            }
            task.beforeSuite { descriptor -> emit('suiteStarted', descriptor, null) }
            task.afterSuite { descriptor, result -> emit('suiteFinished', descriptor, result) }
            task.beforeTest { descriptor -> emit('testStarted', descriptor, null) }
            task.afterTest { descriptor, result -> emit('testFinished', descriptor, result) }
            task.onOutput { descriptor, event ->
                synchronized (occurrences) {
                    // Older Gradle runners often publish only the suite descriptor with output.
                    def owner = descriptor
                    while (owner != null && !occurrences.containsKey(owner)) { owner = owner.parent }
                    def node = owner == null ? taskNode(task) : occurrences.get(owner)
                    byte[] bytes = event.message.getBytes('UTF-8')
                    journal.emit([kind: 'output', build: build, module: project.path, task: task.path, nodeID: node],
                                 bytes, event.destination.name())
                }
            }
        }
    }
    """#
}
