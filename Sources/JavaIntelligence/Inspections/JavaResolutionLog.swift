import Foundation
import os

/// Opt-in trace of every "this class does not exist" decision the inspections make, and of every
/// one they declined to make because the index could not prove it. Set
/// `UMBRA_JAVA_RESOLUTION_LOG=1` in the app's environment and read the `Penumbra` /
/// `JavaResolution` category in Console (or `log stream --predicate 'category == "JavaResolution"'`).
///
/// Each line answers "why was this exact name considered missing, and was the lookup context
/// complete enough to say so": the rule, the name, the file, the index's ``JavaIndex/sourcesVersion``,
/// whether the platform (`java.lang.Object`) is indexed, whether the host declared the classpath
/// complete, and the query scope (how many shards the file's source set sees, or `all`). File paths
/// are logged as private; no source text is logged. Off, each call is one static Bool check.
enum JavaResolutionLog {
    static let isEnabled = ProcessInfo.processInfo.environment["UMBRA_JAVA_RESOLUTION_LOG"] == "1"
    private static let log = Logger(subsystem: "Penumbra", category: "JavaResolution")

    /// A name no visible class bears, reported against an index that can prove absence.
    static func missing(rule: String, name: String, url: URL?, index: JavaIndex) async {
        guard isEnabled else { return }
        let state = await State(index: index)
        log.debug("""
            missing rule=\(rule, privacy: .public) name=\(name, privacy: .public) \
            file=\(url?.path ?? "-", privacy: .private) \(state.description, privacy: .public) \
            reason=no-visible-class-with-simple-name
            """)
    }

    /// Names a rule did not judge because the index cannot prove absence yet.
    static func pending(rule: String, names: [String], url: URL?, index: JavaIndex) async {
        guard isEnabled else { return }
        let state = await State(index: index)
        let reason = !state.hasPlatform ? "platform-not-indexed"
            : !state.classpathComplete ? "classpath-incomplete"
            : "module-shards-missing(\(state.missingShards))"
        log.debug("""
            pending rule=\(rule, privacy: .public) names=\(names.count) \
            file=\(url?.path ?? "-", privacy: .private) \(state.description, privacy: .public) \
            reason=\(reason, privacy: .public)
            """)
    }

    private struct State {
        let sourcesVersion: Int
        let hasPlatform: Bool
        let classpathComplete: Bool
        let missingShards: Int
        let scope: String

        init(index: JavaIndex) async {
            sourcesVersion = await index.sourcesVersion
            hasPlatform = await index.hasPlatformClasses
            classpathComplete = await index.classpathComplete
            missingShards = await index.missingRequiredShards.count
            scope = JavaIndex.queryScope.map { "\($0.count)-shards" } ?? "all"
        }

        var description: String {
            "sourcesVersion=\(sourcesVersion) platform=\(hasPlatform) classpathComplete=\(classpathComplete) scope=\(scope)"
        }
    }
}
