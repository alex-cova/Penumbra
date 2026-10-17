import Foundation

/// One analysis server per JDK home, shared across windows: the server's cached file managers
/// already hold the project's jars open, so a second process for the same JDK would only
/// double the memory. (The `JavaSharedShardHub` precedent for sharing expensive per-JDK state.)
public actor JavaAnalysisServerHub {
    public static let shared = JavaAnalysisServerHub()

    private var clients: [String: JavaAnalysisServerClient] = [:]

    /// The client for `javaHome`, creating (but not starting) it on first use. The server
    /// process itself starts lazily on the first request. `jarURL` and `maxHeapMB` stick from
    /// the first call for a home.
    public func client(jarURL: URL, javaHome: URL, maxHeapMB: Int = 512) -> JavaAnalysisServerClient {
        let key = javaHome.standardizedFileURL.path
        if let existing = clients[key] { return existing }
        let created = JavaAnalysisServerClient(configuration: JavaAnalysisServerConfiguration(
            jarURL: jarURL,
            javaExecutable: javaHome.appendingPathComponent("bin/java"),
            maxHeapMB: maxHeapMB
        ))
        clients[key] = created
        return created
    }

    /// Forgets every client (shutting each server down). Tests use this for isolation.
    public func reset() async {
        let known = clients
        clients = [:]
        for client in known.values { await client.shutdown() }
    }
}
