import Foundation

/// The Gradle init script that starts Flight Recorder in the JVM of `run`, `bootRun` and test
/// tasks, so a Gradle launch can be profiled the way a plain `main` is.
///
/// Every task writes `<dir>/<tag>-%p.jfr` (`%p` is the process id, so forked test JVMs each get a
/// file), and the importer reads every `.jfr` in the run directory.
public enum JavaProfileGradleScript {
    public static let directoryProperty = "umbraProfileDir"
    public static let settingsProperty = "umbraProfileSettings"
    public static let stackDepthProperty = "umbraProfileStackDepth"
    /// Event settings (`jdk.ExecutionSample#period=5ms,…`), already comma-joined.
    public static let optionsProperty = "umbraProfileOptions"
    /// The run's id; every forked JVM gets `-Dumbra.profile.run=<id>`, which `jps -v` shows.
    public static let runProperty = "umbraProfileRun"

    public static let source = #"""
    import org.gradle.api.tasks.JavaExec
    import org.gradle.api.tasks.testing.Test

    allprojects { p ->
        def attach = { t ->
            if (!p.hasProperty('umbraProfileDir')) { return }
            t.doFirst {
                String tag = (p.path == ':' ? 'root' : p.path.substring(1).replace(':', '_')) + '-' + t.name
                String settings = p.hasProperty('umbraProfileSettings') ? p.property('umbraProfileSettings') : 'profile'
                String options = 'name=umbra,filename=' + new File(p.property('umbraProfileDir').toString(), tag + '-%p.jfr').path +
                    ',settings=' + settings + ',dumponexit=true'
                if (p.hasProperty('umbraProfileOptions')) {
                    options += ',' + p.property('umbraProfileOptions')
                }
                t.jvmArgs('-XX:StartFlightRecording=' + options)
                if (p.hasProperty('umbraProfileRun')) {
                    t.jvmArgs('-Dumbra.profile.run=' + p.property('umbraProfileRun'))
                }
                if (p.hasProperty('umbraProfileStackDepth')) {
                    t.jvmArgs('-XX:FlightRecorderOptions=stackdepth=' + p.property('umbraProfileStackDepth'))
                }
            }
        }
        p.tasks.withType(JavaExec).configureEach { t -> attach(t) }
        p.tasks.withType(Test).configureEach { t ->
            if (!p.hasProperty('umbraProfileDir')) { return }
            // An up-to-date test task starts no JVM to record.
            t.outputs.upToDateWhen { false }
            t.outputs.cacheIf { false }
            attach(t)
        }
    }
    """#

    public static func arguments(
        scriptURL: URL, recordingDirectory: URL, options: JavaFlightRecorderOptions, jdkFeatureVersion: Int?,
        runID: String? = nil
    ) -> [String] {
        var result = [
            "--init-script", scriptURL.path,
            "-P\(directoryProperty)=\(recordingDirectory.path)",
            "-P\(settingsProperty)=\(options.template.settingsValue)",
            "-P\(stackDepthProperty)=\(min(max(options.stackDepth, 1), JavaFlightRecorder.maximumStackDepth))"
        ]
        let events = options.eventSettings(jdkFeatureVersion: jdkFeatureVersion)
        if !events.isEmpty { result.append("-P\(optionsProperty)=\(events.joined(separator: ","))") }
        if let runID { result.append("-P\(runProperty)=\(runID)") }
        result += ["--no-configuration-cache", "--no-build-cache"]
        return result
    }

    public static func arguments(
        scriptURL: URL, recordingDirectory: URL, settings: String = "profile",
        samplePeriodMilliseconds: Int? = nil, jdkFeatureVersion: Int? = nil,
        stackDepth: Int = JavaFlightRecorder.defaultStackDepth
    ) -> [String] {
        var options = JavaFlightRecorderOptions(
            template: .init(settingsValue: settings), samplePeriodMilliseconds: samplePeriodMilliseconds
        )
        options.stackDepth = stackDepth
        return arguments(scriptURL: scriptURL, recordingDirectory: recordingDirectory, options: options, jdkFeatureVersion: jdkFeatureVersion)
    }

    /// The recordings in `directory`, largest first (a worker JVM's file beats an empty daemon's).
    public static func recordings(in directory: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return [] }
        let files = entries.filter { $0.pathExtension == "jfr" }
        func size(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        return files.sorted { size($0) > size($1) }
    }
}
