import Foundation
import XCTest
@testable import JavaIntelligence

/// Shared scaffolding for the parity tests (`JavaAnalysisServerTests`, `JavaParityCorpusTests`):
/// JDK discovery, building the analysis-server jar, and a configured client. Everything skips
/// (rather than fails) without a JDK.
enum ParityTestSupport {
    struct Environment {
        let jdk: JDKInstallation
        let jarURL: URL
    }

    static func requireJDK() throws -> JDKInstallation {
        guard let found = TestJDK.discovered else { throw XCTSkip("No JDK installed") }
        guard let jdk = ReleaseFileParser.parse(found.home), jdk.javac != nil else {
            throw XCTSkip("The discovered JDK has no javac")
        }
        return jdk
    }

    private static let jarLock = NSLock()
    private nonisolated(unsafe) static var cachedJarURL: URL?

    /// Builds `java-analysis-server.jar` into a temporary directory (once per test process).
    static func requireServerJar() throws -> URL {
        if let jarURL = jarLock.withLock({ cachedJarURL }) { return jarURL }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("java-analysis-server-build-\(UUID().uuidString)")
        // #filePath is Tests/PenumbraTests/JavaIntelligence/Parity/<file>; five levels up is the root.
        let build = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Example/Umbra/Tools/JavaAnalysisServer/build.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [build.path]
        var environment = ProcessInfo.processInfo.environment
        environment["BUILD_OUT"] = out.path
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ParityTestError.serverBuildFailed }
        let jar = out.appendingPathComponent("java-analysis-server.jar")
        guard FileManager.default.fileExists(atPath: jar.path) else { throw ParityTestError.serverJarMissing }
        jarLock.withLock { cachedJarURL = jar }
        return jar
    }

    static func requireEnvironment() throws -> Environment {
        Environment(jdk: try requireJDK(), jarURL: try requireServerJar())
    }

    static func makeClient(jarURL: URL, jdk: JDKInstallation, idleTimeout: Duration = .seconds(600)) -> JavaAnalysisServerClient {
        JavaAnalysisServerClient(configuration: JavaAnalysisServerConfiguration(
            jarURL: jarURL,
            javaExecutable: jdk.home.appendingPathComponent("bin/java")
        ), idleTimeout: idleTimeout)
    }

    /// Committed parity fixtures in the test bundle (`Fixtures/JavaParityCorpus/<directory>`).
    static func fixtureDirectory(_ directory: String) throws -> URL {
        guard let resourceURL = Bundle.module.resourceURL else { throw ParityTestError.fixturesMissing }
        for candidate in [
            resourceURL.appendingPathComponent("JavaParityCorpus/\(directory)"),
            resourceURL.appendingPathComponent("Fixtures/JavaParityCorpus/\(directory)"),
        ] where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        throw ParityTestError.fixturesMissing
    }
}

enum ParityTestError: Error {
    case serverBuildFailed
    case serverJarMissing
    case fixturesMissing
}
