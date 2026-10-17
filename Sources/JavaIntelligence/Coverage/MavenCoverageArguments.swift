import Foundation

/// Maven test-run arguments for coverage and profiling. Both travel as Surefire's `argLine`.
/// A module that already runs `jacoco-maven-plugin` `prepare-agent` keeps that agent. A Surefire
/// `argLine` that does not mention `@{argLine}` or `${argLine}` replaces the property, so an
/// injected agent never reaches the test JVM.
public enum MavenCoverageArguments {
    public struct Result: Sendable, Equatable {
        public var arguments: [String]
        /// Why coverage or profiling cannot be applied. One sentence.
        public var explanation: String?
        /// The exec file JaCoCo's own `prepare-agent` writes, when the module has that goal.
        public var moduleExecFile: URL?

        public init(arguments: [String], explanation: String? = nil, moduleExecFile: URL? = nil) {
            self.arguments = arguments
            self.explanation = explanation
            self.moduleExecFile = moduleExecFile
        }
    }

    public static let blockedExplanation =
        "Surefire's argLine does not include @{argLine}, so a coverage agent cannot reach the tests."

    public static func arguments(
        module: MavenModule,
        coverageAgent: String? = nil,
        flightRecorder: String? = nil
    ) -> Result {
        if module.usesJacocoPrepareAgent {
            return Result(
                arguments: [],
                moduleExecFile: module.directory.appendingPathComponent("target/jacoco.exec")
            )
        }
        let injected = [coverageAgent, flightRecorder].compactMap { $0 }.filter { !$0.isEmpty }
        guard !injected.isEmpty else { return Result(arguments: []) }
        if let argLine = module.surefireArgLine, !acceptsInjectedArgLine(argLine) {
            return Result(arguments: [], explanation: blockedExplanation)
        }
        return Result(arguments: ["-DargLine=\(injected.joined(separator: " "))"])
    }

    /// Coverage for a Maven test run. `nil` agent paths produce no arguments.
    public static func coverage(
        module: MavenModule,
        agentJar: URL,
        execFile: URL,
        includes: String? = nil
    ) -> Result {
        arguments(
            module: module,
            coverageAgent: JavaCoverageCommand.agentArgument(agentJar: agentJar, execFile: execFile, includes: includes)
        )
    }

    /// Profiling for a Maven test run. `nil` when the recording path cannot be carried.
    public static func profiling(
        module: MavenModule,
        recordingFile: String,
        jdkFeatureVersion: Int? = nil
    ) -> Result {
        arguments(
            module: module,
            flightRecorder: JavaFlightRecorder.vmArgument(file: recordingFile, jdkFeatureVersion: jdkFeatureVersion)
        )
    }

    /// Surefire copies `@{argLine}` (and `${argLine}`) from the `argLine` property into the POM value.
    public static func acceptsInjectedArgLine(_ argLine: String) -> Bool {
        argLine.contains("@{argLine}") || argLine.contains("${argLine}")
    }
}
